# Project Description

Production-grade AWS plan for a **secure, scalable, resilient, extensible chatbot platform** that can handle thousands of concurrent users (and grow beyond). Designed for **Terraform**, **Docker**, **Python (FastAPI)** backend, and **Next.js** frontend, with clean separation of concerns and strong operational foundations.

---

## 1. Target Architecture (High Level)

**Core idea:** Keep chat traffic stateless at the API layer, store “session/conversation” state in durable stores, and use Redis only for fast ephemeral state (rate-limits, streaming buffers, locks). Use async workers for heavy tasks (RAG ingestion, long tools, file processing).

### Recommended AWS Building Blocks

| Layer | Services |
|-------|----------|
| **Edge & Web** | Route 53 (DNS), ACM (TLS), CloudFront (CDN + caching + WAF), AWS WAF, S3 (static assets, uploads) |
| **Auth** | Cognito User Pools (or Auth0; Cognito keeps it AWS-native) |
| **Compute** | ECS Fargate (API + optional Web for Next.js SSR); separate ECS services for api, workers, (optional) web; ECR (container registry) |
| **Data** | DynamoDB (chat/messages + request tracking + idempotency), ElastiCache Redis (rate limiting, presence, streaming state, locks), Aurora Postgres (optional: billing, orgs, admin, analytics), S3 (attachments, templates, logs, exports) |
| **Async** | SQS (job queue), EventBridge (event bus), Step Functions (optional for multi-step pipelines) |
| **Observability** | CloudWatch Logs + Metrics + Alarms, OpenTelemetry + AWS X-Ray (or ADOT), optional Managed Prometheus/Grafana |
| **Security** | KMS (encryption), Secrets Manager (API keys, sensitive config), VPC endpoints (PrivateLink), GuardDuty + Security Hub (recommended) |

---

## 2. Request & Chat Flow Design

### 2.1 Frontend Flow (Next.js)

- Next.js app served via **CloudFront**.
- **Option A:** Mostly static + API-driven → static assets in S3, dynamic UI hits the API.
- **Option B (SSR):** Next.js in ECS Fargate behind ALB, still fronted by CloudFront.

### 2.2 Auth Flow

- Users authenticate via **Cognito**.
- Frontend gets JWT access token.
- Backend validates JWT using Cognito JWKS; identity becomes `user_id` + (optional) `tenant_id`.

### 2.3 Chat Flow (Streaming)

- Use **SSE (Server-Sent Events)** for streaming responses (simpler than WebSockets for token stream, works well behind ALB/CloudFront).
- **Client:** `POST /v1/chat` (or `/v1/chat/stream`) with JWT.
- **API:**
  - Rate-limit check in Redis (token bucket per user/tenant + global).
  - Persist request metadata to DynamoDB (idempotency key).
  - Load conversation context (DynamoDB) + short memory (Redis) if needed.
  - Optional retrieval (vector DB) + tool calls.
  - Stream tokens back via SSE.
  - Persist assistant message + usage to DynamoDB/Aurora.

### 2.4 Async Jobs

- Heavy work (document ingestion, embeddings, file parsing, long tool calls) goes to **SQS**.
- API enqueues job → Worker consumes → writes results → client polls or receives via SSE “job status” channel.

---

## 3. Data Model Choices

### 3.1 DynamoDB Tables (Minimum Recommended)

**Conversations**

- **PK:** `TENANT#{tenant_id}#USER#{user_id}`
- **SK:** `CONV#{conversation_id}`
- **Attributes:** title, created_at, updated_at, model, settings

**Messages**

- **PK:** `CONV#{conversation_id}`
- **SK:** `TS#{timestamp}#MSG#{message_id}`
- **Attributes:** role, content, tokens_in/out, tool_calls, attachments, safety flags

**Requests / Idempotency**

- **PK:** `REQ#{idempotency_key}`
- **Attributes:** user_id, status, created_at, response_ref, ttl

*Rationale:* High concurrency, predictable scaling, simple partitioning.

### 3.2 Redis Usage (ElastiCache)

Use Redis only for **fast + ephemeral**:

- Rate limiting counters / token buckets
- Streaming coordination (resumable streams if needed)
- Short-lived conversation locks (avoid double-processing)
- Presence / connection tracking
- Caching retrieved context chunks (short TTL)

### 3.3 Vector Search (RAG)

Choose one (keep pluggable via a `VectorStore` interface):

- **OpenSearch Serverless (vector):** Fully managed, scalable, good for multi-tenant search.
- **Aurora Postgres + pgvector:** Simpler if Aurora is already in use, good for moderate scale.

---

## 4. Compute & Scaling Strategy (ECS Fargate)

### 4.1 ECS Services

- **chat-api** — FastAPI, async, SSE
- **chat-worker** — Celery/RQ-like or custom SQS consumer
- **web** — Next.js SSR (optional if static hosting is sufficient)

### 4.2 Autoscaling

- **chat-api:** CPU + Memory; **RequestCountPerTarget** (ALB) often better than CPU alone; optional custom metric (active streams / concurrent requests).
- **chat-worker:** SQS queue depth (`ApproximateNumberOfMessagesVisible`).

### 4.3 Load Balancing

- ALB in public subnets; ECS tasks in private subnets.
- CloudFront → ALB (origin).
- **SSE:** Tune ALB idle timeouts; API uses keep-alives and periodic SSE comments to keep the pipe open.

### 4.4 Resilience

- Multi-AZ subnets; ECS service spread across AZs.
- DynamoDB regional multi-AZ by default.
- ElastiCache Redis Multi-AZ with auto-failover (cluster mode if needed).
- Aurora Multi-AZ (if used).

---

## 5. Networking & Security

### 5.1 VPC Layout

- 3 AZs.
- **Public subnets:** ALB, NAT Gateways (if needed).
- **Private subnets:** ECS tasks, Redis, Aurora.
- **Isolated subnets (optional):** Databases with no route to internet.

### 5.2 Minimize Outbound Risk

- Prefer **VPC endpoints** for: S3, DynamoDB, ECR (api+dkr), CloudWatch Logs, Secrets Manager, SSM.
- NAT only when calling external APIs (e.g. OpenAI). With Bedrock, traffic can stay more AWS-native.

### 5.3 IAM and Secrets

- One task role per service (least privilege).
- Secrets in Secrets Manager, injected at runtime.
- KMS encryption: S3 SSE-KMS, DynamoDB KMS, Aurora KMS.

### 5.4 Edge Protection

- **CloudFront + WAF:** Rate-based rules per IP, bot mitigation, block obvious scanners.
- **App-level:** Redis rate limits per user/tenant; per-tenant quotas (requests/min, tokens/day).

### 5.5 Tenant Isolation (Extensible)

- Include `tenant_id` in JWT claims.
- Partition DynamoDB keys by tenant.
- Prefix S3 paths: `s3://bucket/tenant={tenant_id}/...`
- Optional: per-tenant KMS keys for stronger isolation later.

---

## 6. Backend Service Architecture (FastAPI)

### 6.1 Key Design Patterns

- **Provider abstraction:** `LLMProvider` interface (OpenAI, Bedrock, Anthropic, etc.).
- **Tool framework:** Registry of tools with strict input/output schemas (Pydantic).
- **Conversation orchestrator:** Builds prompt/messages, optional retrieval, optional tool execution, streams output.

### 6.2 Concurrency & Performance

- Uvicorn with async workers; `httpx.AsyncClient` with connection pooling.
- **Backpressure:** Cap concurrent in-flight requests per task; reject/queue when overloaded (429 + retry-after).
- Timeouts and circuit breakers for external calls.

### 6.3 Persistence Discipline

- Write user message immediately (DynamoDB).
- Stream assistant output; write final assistant message at end.
- Store usage metrics (tokens, latency, provider errors).

---

## 7. Frontend Architecture (Next.js)

| Option | Approach | Use case |
|--------|----------|----------|
| **A** | Static Next.js → S3 + CloudFront; API calls to chat-api behind CloudFront/ALB | Simplest, robust, great performance and low cost |
| **B** | Next.js in ECS Fargate behind same ALB; CloudFront routes `/api/*` → chat-api, `/*` → web | When SSR is heavily needed |

---

## 8. CI/CD and Environments (Terraform-First)

### 8.1 Environments

- **dev**, **staging**, **prod** (separate AWS accounts if possible).
- **Terraform remote state:** S3 backend + DynamoDB lock table.
- **Configuration:** SSM Parameter Store (non-secrets), Secrets Manager (secrets).

### 8.2 Pipeline (e.g. GitHub Actions)

- On push: lint/test → build Docker images → push to ECR → deploy ECS (rolling or blue/green).
- **Blue/green:** CodeDeploy with ECS for safer production releases.

---

## 9. Terraform Project Structure

```
repo/
  apps/
    web/                    # Next.js
  services/
    chat-api/               # FastAPI
    chat-worker/            # SQS consumer / background tasks
  infra/
    terraform/
      live/
        dev/
          main.tf
          variables.tf
          outputs.tf
        staging/
        prod/
      modules/
        network/            # VPC, subnets, routes, endpoints
        edge/               # CloudFront, WAF, ACM, Route53
        ecs-cluster/        # ECS, capacity, logs
        ecs-service/        # task defs, services, autoscaling
        alb/                # listeners, target groups
        dynamodb/           # tables
        redis/              # ElastiCache
        aurora/             # optional
        s3/                 # uploads, static
        observability/      # alarms, dashboards
        security/           # KMS, secrets, GuardDuty (optional)
```

---

## 10. Observability & Operations

### Metrics (Minimum)

- p50/p95/p99 latency for chat endpoints
- Concurrent streams
- Error rates by provider + endpoint
- Token usage per tenant/user
- SQS queue depth + worker lag
- Redis CPU/memory/evictions
- DynamoDB throttles (target: near zero)

### Logging

- Structured JSON logs.
- Redact secrets/PII.
- Correlate with `request_id` and `conversation_id`.

---

## 11. Milestone Ladder (Incremental, Production-Grade)

Each milestone strictly builds on the previous. Descriptions below are scope + outcomes only. After the ladder is approved, each milestone is turned into a technical document (architecture, Terraform modules, configs, data models, API specs, SLOs, runbooks, tests, rollout/rollback).

**Milestone technical docs:** [internal_project_docs/milestones/](./milestones/) — M0–M19 have full technical specs.

| # | Milestone | Outcome | Includes |
|---|-----------|---------|----------|
| **M0** | Product & Non-Functional Requirements (NFRs) | Written spec for scale, latency, security, compliance, costs | Target concurrency, token throughput, regions, retention, tenant model, PII rules, SLOs/SLAs, threat model baseline |
| **M1** | Repo + Engineering Standards (Monorepo + CI skeleton) | Ready-to-build platform skeleton | Monorepo layout (web/api/worker/infra), Docker standards, code style, pre-commit, CI pipeline (lint/test/build), release tagging, environment strategy (dev/stage/prod) |
| **M2** | Terraform Foundation + Remote State + Environment Isolation | Safe infrastructure workflow | S3 backend + DynamoDB locks, workspace/account separation, Terraform modules convention, IAM for CI deploy roles, drift detection, tagging policy |
| **M3** | Network Baseline (VPC, subnets, routing, endpoints) | Secure network “landing zone” for services | Multi-AZ VPC, public/private subnets, ALB placement, NAT strategy, VPC endpoints (S3/DynamoDB/ECR/Logs/Secrets), security group baseline |
| **M4** | Identity & Access (AuthN/AuthZ baseline) | Real user auth and least-privilege internal access | Cognito (or OIDC), JWT validation, RBAC model, service IAM task roles, Secrets Manager access patterns |
| **M5** | Edge + Frontend Delivery Baseline (CloudFront + WAF) | Internet-facing entry point that’s hardened | Route53 + ACM TLS, CloudFront for web + API routing strategy, WAF baseline rules (rate limits/bot rules), secure headers, static hosting vs SSR decision locked |
| **M6** | Core Chat API v1 (Stateless, Streaming-ready) | Scalable API service for thousands of concurrent requests | FastAPI service, SSE streaming, request validation, request IDs, graceful shutdown, health endpoints, basic error taxonomy |
| **M7** | Conversation Storage v1 (Durable State + Idempotency) | Correctness under retries and scale | DynamoDB tables for conversations/messages, idempotency table/keys, message ordering, TTL policies, attachment metadata pointers (S3) |
| **M8** | Redis Layer v1 (Rate Limits + Ephemeral State) | Predictable behavior under load and abuse | ElastiCache Redis, per-user/per-tenant rate limits, burst control, short-lived caches (optional), distributed locks (only where needed) |
| **M9** | ECS/Fargate Productionization (Autoscaling + Deploy Safety) | Robust compute layer that scales automatically | ECS services (api + optional web), task definitions, ALB target groups, autoscaling policies (CPU + request count), deployment strategy (rolling first) |
| **M10** | Observability v1 (Logs, Metrics, Traces, Alarms) | Operate it like a real platform | Structured JSON logs, correlation IDs, CloudWatch dashboards, alarms, basic tracing (OpenTelemetry/X-Ray), latency/error SLO measurements |
| **M11** | Load Testing + Performance Tuning Gate | Proven capacity + known limits | k6/locust test suite, concurrency targets, SSE soak tests, bottleneck fixes (connection pools, timeouts), scale curves + cost estimates |
| **M12** | Async Jobs Platform (Workers + Queues) | Heavy workloads don’t break chat latency | SQS queues, worker ECS service, retries/DLQ, job status model, async endpoints, long tool execution moved off the request path |
| **M13** | Tool/Plugin Framework v1 (Extensibility with Guardrails) | Safe, governed “tools” (APIs/functions) at scale | Tool registry, strict schemas (Pydantic), allowlist controls, timeouts, budgeting, audit logs, sandboxing strategy for risky tools |
| **M14** | RAG v1 (Retrieval + Ingestion Pipeline) | “Knowledge-based chatbot” capability | Vector store choice + abstraction, ingestion jobs (S3 → parse → chunk → embed → index), tenant partitioning, retrieval evaluation harness |
| **M15** | Multi-Tenant Hardening (Quotas, Isolation, Abuse Controls) | Platform-ready for many orgs and paid tiers | Tenant IDs everywhere, per-tenant quotas, usage metering (tokens, storage, jobs), throttles, S3 prefix isolation, stronger keying strategy |
| **M16** | Security Hardening v2 (Defense-in-depth) | Security posture suitable for serious production | IAM boundaries, KMS everywhere, secret rotation patterns, WAF tuned rules, dependency scanning, container scanning, GuardDuty/SecurityHub |
| **M17** | Reliability & DR (Backups, Restore, Regional Strategy) | Survivability and recoverability | DynamoDB backup/restore plan, Redis/Aurora recovery plan, S3 versioning & lifecycle, runbooks, chaos testing basics, RPO/RTO targets |
| **M18** | FinOps + SLO Operations (Cost + On-call readiness) | Stable costs and operational excellence | Cost dashboards, scaling tuning, reserved capacity strategy (where applicable), incident playbooks, postmortem template, release checklist |
| **M19** | Enterprise Security & Compliance v1 (SSO, SCIM, RBAC/ABAC, Audit, SOC2-Ready) | Enterprise-ready governance and evidence | SSO (SAML/OIDC), SCIM provisioning/deprovisioning, immutable audit logs, data residency, retention/deletion/legal hold, encryption hardening, SOC2-aligned controls |

### What We’ll Produce Next (Per Milestone)

For each milestone, the **technical doc** will include:

- **Architecture diagram** + sequence diagrams
- **Terraform module changes** (resources, variables, outputs)
- **Service configs** (ECS task defs, autoscaling, ALB/CloudFront/WAF)
- **Data models** (DynamoDB key design, TTL, indexes)
- **API spec** (endpoints, auth, streaming contracts, error codes)
- **Security controls** (IAM policy snippets, secrets, KMS, network rules)
- **Testing plan** (unit/integration/load), rollout/rollback, and runbook

*Next step: start with M0 and write the first technical doc (NFR + SLO + threat model + capacity targets), then proceed milestone by milestone.*

---

## 12. Production Defaults (Avoid Surprises)

- Enforce **idempotency keys** for chat requests (avoids double-billing / duplicates).
- **Strict timeouts** for provider calls + retries with jitter.
- Use **WAF + app rate limits** (both).
- Store **conversation history in DynamoDB**, not in-memory.
- **Separate workers from API tasks** (do not mix).
- Use **VPC endpoints** aggressively; minimize NAT.
- **Encrypt** with KMS; keep secrets in Secrets Manager.
- Design from day one with **tenant_id** (even if starting single-tenant).

---

*This document summarizes the target architecture for the chatbot platform. It can be extended with a full Terraform skeleton, FastAPI service template (SSE + Redis rate limit + DynamoDB), and Next.js template wired to Cognito + streaming UI, in a repo structure that matches this plan.*
