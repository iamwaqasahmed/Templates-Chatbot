# M0 — Product & Non-Functional Requirements (NFR) Technical Spec (v1)

This document defines what "production-grade" means for your chatbot platform before we build anything. It becomes the yardstick for architecture, Terraform, scaling, security, testing, and operations.

---

## 0.1 Purpose

Build a multi-tenant chatbot platform on AWS that:

- supports thousands of concurrent users
- streams responses (SSE)
- is secure by default (least privilege, encryption, WAF, rate limits)
- is operable (metrics, traces, alarms, runbooks)
- is extensible (tools/plugins, RAG, async jobs)
- can evolve into an "enterprise-ready" system

---

## 0.2 Assumptions (explicit defaults for v1)

These are the defaults we'll design around unless you later override them.

**Users & traffic**

- Peak concurrent users (interactive): **2,000**
- Peak requests per second (RPS): **100–300 RPS** (mix of short + streaming)
- Avg user messages: ~10–50 per day (varies by product)
- Response mode: **SSE streaming** for most chats

**Model provider**

- Primary: **OpenAI API or AWS Bedrock** (design is provider-agnostic)
- Provider latency is the dominant factor; system SLOs separate "platform latency" vs "model latency".

**Tenancy**

- **Multi-tenant from day 1** (even if you have 1 tenant at launch)
- Tenant controls: quotas, token budgets, storage limits, rate limits.

**Data sensitivity**

- Assume user text may contain PII (emails, phone numbers, names), so:
  - strict log redaction
  - encryption everywhere
  - retention policies

---

## 0.3 Scope

**In-scope (platform baseline)**

- Auth (Cognito/OIDC), user identity, tenant identity
- Chat API with streaming
- Durable conversation storage
- Rate limiting + abuse controls
- Observability + SLOs + alarms
- CI/CD + infra as code (Terraform)

**Explicitly out-of-scope for M0 (but planned later)**

- RAG ingestion and vector store (later milestone)
- Tool/plugin system (later milestone)
- Billing/paid plans (later milestone)
- Multi-region active-active (later milestone)

---

## 0.4 Personas & Access Model

**Personas**

| Persona | Description |
|--------|-------------|
| **End User** | Chats, sees history, uploads attachments (optional) |
| **Tenant Admin** | Manages users, quotas, allowed tools, retention policy |
| **Platform Operator (DevOps/SRE)** | Deploys, monitors, responds to incidents |
| **Developer** | Adds tools, integrates RAG sources, improves prompts |

**Core identity primitives**

- `tenant_id`, `user_id`, `roles[]`, `plan_tier`, `features[]`
- Every request must resolve to `{tenant_id, user_id}`

---

## 0.5 Functional Requirements (MVP definition)

**Chat**

- Create conversation
- Send message
- Stream assistant response (SSE)
- Retrieve conversation history
- Regenerate last response (idempotent)
- Basic model settings per tenant (model name, temperature, max tokens)

**Governance**

- Per-tenant feature flags (enable/disable tools, attachments)
- Per-tenant quotas (requests/min, tokens/day)

**Operational essentials**

- Health checks (`/health`, `/ready`)
- Request correlation ID
- Audit events for security-sensitive operations (admin changes)

---

## 0.6 Non-Functional Requirements (measurable)

### 0.6.1 Availability (SLO)

- **API Availability SLO:** 99.9% monthly for `POST /chat` and `GET /conversations/*`
- **Error budget:** ~43 minutes/month
- **SSE Stream Stability SLO:** 99.5% of streams must not terminate due to platform error (provider failure excluded).

**Definition of "platform error":**

- 5xx responses from API
- Stream breaks due to gateway/service issues (not user disconnect)

### 0.6.2 Latency (SLOs)

We define two sets: platform-only and end-to-end.

**Platform-only** (excluding model provider time):

- p95 request overhead (auth + validation + persistence + retrieval from DB/cache): **< 150ms**

**End-to-end** (including model provider):

- p95 **Time-To-First-Token (TTFT):** < 2.5s
- p95 completion time for "short answers" (≤ 250 tokens output): < 8s
- p99 TTFT: < 6s

*Note: TTFT depends heavily on model/provider; we'll track it separately by provider/model.*

### 0.6.3 Throughput & Concurrency

- Support **2,000 concurrent active streams** at peak (initial target)
- Support **300 RPS burst** for non-stream endpoints (history, metadata)
- **Backpressure:** system must return **429** (not 5xx) under overload

### 0.6.4 Scalability & Elasticity

- Horizontal autoscaling for API + workers
- Scale-out time target: **< 5 minutes** from sustained load increase
- No single-node bottlenecks: API must be stateless; state stored in DynamoDB/S3/Redis

### 0.6.5 Durability & Consistency

- Conversation messages are **durable once acknowledged**
- **Idempotency guarantees:** duplicate `POST /chat` with same idempotency key must not create duplicate assistant messages
- **Message ordering:** messages must be strictly ordered per conversation
- **Data loss tolerance:** 0 loss of persisted messages; streaming partial tokens may be lost on disconnect; final message must persist when completed

### 0.6.6 Cost Constraints (FinOps targets)

- Define cost per 1K chats and per 1M tokens by tier
- **Platform overhead target** (excluding model tokens): < 20–30% of total cost at steady state (goal; tuned later)
- Autoscaling must avoid "always-on excess" capacity in low traffic

### 0.6.7 Maintainability & Extensibility

- **Clear layering:** API (FastAPI) → Orchestrator → Provider interface → Persistence
- Add new model provider with no API contract changes
- Add new tool with: schema + allowlist + audit
- Everything deployable via Terraform with consistent module patterns

---

## 0.7 Data, Privacy, and Retention Requirements

**Data classes**

- **User Content:** chat text, uploads
- **Metadata:** timestamps, user IDs, tenant IDs, model, token usage
- **Operational Logs:** request IDs, latency, error codes (no raw PII)

**Minimum privacy requirements**

- Encrypt at rest everywhere (KMS)
- Encrypt in transit everywhere (TLS)
- **Log redaction:** do not log raw prompts/responses by default in production; optionally store "debug traces" behind tenant/admin opt-in with short retention

**Retention defaults (recommended)**

- Conversations: 90–365 days configurable per tenant
- Logs: 14–30 days hot, then archive if needed
- Attachments: lifecycle rules (e.g., transition to IA, expire after policy)

**Data deletion**

- Support tenant-wide and user-level deletion requests: "delete conversation", "delete user data"
- Deletion must cover: DynamoDB items, S3 objects, vector index entries (future milestone), derived caches (Redis)

---

## 0.8 Security Requirements (baseline controls)

**Authentication**

- OIDC (Cognito) JWT validation on every request
- Short token lifetimes; refresh token flow on frontend

**Authorization**

- **RBAC:** user, tenant_admin, platform_admin
- Every read/write must validate `tenant_id` boundary

**Network security**

- Private subnets for compute and data stores
- No direct public access to Redis/DB
- **WAF at CloudFront:** rate-based rules, bot/scanner rules, geo/IP allow/deny

**Secrets**

- Secrets Manager for provider keys, encryption salts, service credentials
- No secrets in images or Terraform state

**Abuse prevention**

- **Rate limits:** per IP (WAF), per user & per tenant (Redis)
- **Quotas:** daily token budget per tenant, concurrency cap per tenant (streams)

**Supply chain**

- Container scanning (ECR scan or equivalent)
- Dependency scanning in CI (SCA)
- Signed images (optional but recommended later)

---

## 0.9 Observability Requirements

**Required telemetry**

| Type | Requirements |
|------|--------------|
| **Metrics** | RPS per endpoint; p50/p95/p99 latency; active streams; model provider latency + error rate; DynamoDB throttles/latency; Redis CPU/mem/evictions |
| **Logs** | Structured JSON; correlation IDs: request_id, conversation_id, user_id_hash, tenant_id; never log raw secrets |
| **Traces** | End-to-end request trace with spans: auth → db read → provider call → db write |

**Alerting (minimum)**

- API 5xx error rate > threshold
- Latency p95 breach (platform-only and end-to-end)
- Provider error rate spikes
- DynamoDB throttling > 0 sustained
- Queue backlog (future milestone)
- Redis evictions > 0 sustained

---

## 0.10 Reliability & DR Requirements

**Backups**

- **DynamoDB:** point-in-time recovery (PITR) enabled
- **S3:** versioning + lifecycle policies
- **(If Aurora later)** automated backups + multi-AZ

**RPO / RTO targets (v1)**

- **RPO (data loss):** ≤ 5 minutes (practically 0 for DynamoDB/S3 in-region)
- **RTO (restore service):** ≤ 60 minutes for regional incidents (v1 goal)
- Later milestone can push to multi-region warm standby.

---

## 0.11 Capacity Model (initial sizing inputs)

We track these parameters:

- **C** = concurrent streams
- **R** = requests per second (non-stream)
- TTFT distribution
- Average stream duration
- Tokens/sec per stream (provider-dependent)

**Initial planning envelope:**

- C = **2,000**
- Avg stream duration **20–60s**
- Steady state new streams: ~C / avg_duration → **33–100 new streams/sec**

This matters because the API must handle: many long-lived connections, connection pooling to provider, backpressure and autoscaling based on "active streams" not only CPU.

---

## 0.12 Platform "Definition of Done" for M0

M0 is complete when you have a **signed-off document** containing:

- SLOs/SLIs + error budgets
- Retention + deletion policy
- Tenancy model + quotas
- Security baseline requirements (IAM/network/secrets/logging)
- Capacity assumptions (C/R/TTFT)
- Explicit out-of-scope list for MVP

---

## 0.13 Open Decisions (to lock soon, but not blocking M0)

- Primary LLM provider: OpenAI vs Bedrock vs both (multi-provider failover)
- SSR vs static hosting for Next.js
- DynamoDB-only vs add Aurora early for billing/org features
- Whether to store full prompts/responses for analytics (privacy tradeoff)
- Compliance target (SOC2/GDPR/PIPEDA posture)
