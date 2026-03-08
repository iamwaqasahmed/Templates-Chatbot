# M9 — ECS/Fargate Productionization (ALB, Services, Autoscaling, Deploy Safety, Runtime Hardening) — Technical Design v1

M9 turns the system into a real production service: it runs on ECS Fargate behind an ALB, integrates with CloudFront/WAF routing, scales automatically, deploys safely, and has the operational hardening needed for thousands of concurrent users (especially SSE streams).

This milestone assumes: M3 (network), M4 (auth), M5 (edge), M6 (API), M7 (DynamoDB), M8 (Redis).

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- Run **chat-api** and **chat-worker** on ECS Fargate in private subnets.
- **Public ALB** in public subnets routes traffic to chat-api.
- **CloudFront (M5)** routes api.example.com to ALB origin (recommended).
- **Autoscaling:** API on ALB RequestCountPerTarget + CPU/memory; worker on queue depth (SQS in M12; M9 scaffolds).
- **Deploy safety:** health checks, rolling deployments (optionally blue/green readiness), graceful shutdown (in-flight streams).
- **Operational readiness:** logs, metrics, alarms for ALB/ECS.
- **Secure runtime:** task roles, secrets injection, no public IP, least privilege, restricted egress.

### Non-goals (later)

- Blue/green with CodeDeploy (prepare but not mandatory in v1)
- Multi-region compute/traffic steering (M17)
- Service mesh (optional later)

### Outcomes

- Terraform compute module/stack deploys: ECS cluster, ECR repos, ALB + listeners + target groups, ECS services (api, worker), autoscaling policies, CloudWatch log groups and alarms.
- A production-ish deployment flow exists: build → push → update service.

---

## 2. High-Level Architecture (traffic and components)

### Recommended routing

| Domain | Path | CloudFront | Origin |
|--------|------|------------|--------|
| app.example.com | /* | Yes | S3 (web) |
| api.example.com | /* | Yes | ALB → ECS chat-api |

### ECS services

- **chat-api** — FastAPI + SSE
- **chat-worker** — Background tasks; in M9 can run minimal job loop or placeholder until M12

### Data dependencies

- DynamoDB (M7)
- Redis (M8)
- Secrets Manager (M4 pattern)

---

## 3. VPC Placement & Security (critical)

### Subnets

| Component | Subnet | Public IP |
|-----------|--------|-----------|
| ALB | Public subnets | — |
| ECS tasks | Private-app subnets | No |
| Redis | Private-data subnets | No |

No task gets a public IP.

### Security groups

| SG | Inbound | Outbound |
|----|---------|----------|
| **sg_alb_public** | 443 from CloudFront (ideal) or 0.0.0.0/0 (temporarily) | To sg_api_tasks on API port |
| **sg_api_tasks** | From sg_alb_public on port 8000 (or 8080) | Redis 6379, VPC endpoints 443, NAT (0.0.0.0/0) only if external LLM |
| **sg_worker_tasks** | None (usually) | Redis, DynamoDB, S3 endpoints, NAT if needed |
| **sg_vpce** (M3) | 443 from task SGs | default |

### Locking ALB ingress to CloudFront (best practice)

- **Option:** Custom header (shared secret) added by CloudFront, validated by app/WAF; or restrict ALB SG to CloudFront prefix list (less reliable).
- **Practical v1:** Keep ALB SG open on 443; enforce only CloudFront traffic by validating a header in app / WAF rule (preferred).

---

## 4. ALB Design (SSE-friendly)

### 4.1 Listeners

- **443** listener (TLS) with ACM cert in region
- (Optional) 80 → redirect to 443

### 4.2 Target group

| Setting | Value |
|---------|--------|
| Type | IP (Fargate) |
| Protocol | HTTP (ALB terminates TLS) |
| Health check path | `/ready` (not `/health` if health is too permissive) |
| Health check interval | 15–30s |
| Deregistration delay | Tuned for SSE (see below) |

### 4.3 SSE + graceful drain

- **FastAPI:** On SIGTERM stop accepting new streams; let existing streams finish up to N seconds.
- **Target group:** Deregistration delay e.g. 30–60s (enough for short responses). For very long streams: soft time cap (M6); optionally “server restarting” if drain exceeds cap.

### 4.4 Idle timeouts

- ALB idle timeout default 60s can kill streams. **SSE ping every ~15s (M6)** keeps connection active; CloudFront also benefits.

---

## 5. ECS Cluster & Service Design

### 5.1 ECS cluster

- Fargate (+ optional Fargate Spot for non-critical workers)
- Container Insights optional (costs more)

### 5.2 Task definitions (important fields)

**chat-api**

| Item | Value |
|------|--------|
| CPU/memory | Start 1 vCPU / 2GB (tune after load tests) |
| Port | 8000 |
| Health check | ALB health check primary; container health check optional |
| Logging | awslogs → CloudWatch |
| Env | APP_ENV, table names, redis endpoint, provider config |
| Secrets | Redis auth token, LLM provider key(s) |
| Security | readonlyRootFilesystem where feasible; non-root user; drop capabilities |

**chat-worker**

- CPU/memory smaller (e.g. 0.5 vCPU / 1GB) initially
- Poll loop; later consumes SQS (M12)
- Same secret patterns

### 5.3 Uvicorn/Gunicorn worker model for SSE

- **Recommended:** uvicorn single process per task **or** gunicorn with uvicorn.workers.UvicornWorker.
- Limit is often connections, not CPU; each connection uses memory.
- **Practical starting point:** `gunicorn -k uvicorn.workers.UvicornWorker -w 2 --threads 1`. Tune on memory and connection handling. Cap MAX_CONCURRENT_STREAMS_PER_TASK (M6).

### 5.4 Capacity planning (connection-driven)

Scale chat-api on: active streams per task (custom metric later or ALB proxy), request count per target, CPU, memory.

---

## 6. Autoscaling Strategy (Deep + practical)

### 6.1 chat-api autoscaling signals (recommended mix)

**Target Tracking on:**

| Signal | Role |
|--------|------|
| **ALB RequestCountPerTarget** | Throughput scaling; useful even with long streams |
| **CPU Utilization** | Safety net for heavy processing |
| **Memory Utilization** | Important (streams consume memory) |
| **Optional (best)** | Custom metric: active_streams per task (EMF from app every 10–30s) |

**Baseline**

- **Min tasks:** dev=1, staging=2, prod=3 (multi-AZ)
- **Max tasks:** prod=50+ (budget-based)
- **Cooldowns:** Scale-out faster than scale-in (avoid thrashing)

### 6.2 Scale-out time expectations

- Fargate scale-out can take a couple minutes. Keep small warm pool (min tasks ≥ 3 in prod); WAF + Redis rate limiting prevent runaway.

### 6.3 Worker autoscaling

- M9 scaffolds worker; real scaling in M12 with SQS. For now: fixed desired count (dev=0–1, prod=1–2).

---

## 7. Deployment Strategy (Safe Releases)

### 7.1 Rolling deployment (v1)

- **minimumHealthyPercent** = 100
- **maximumPercent** = 200
- **Health check grace period:** 30–60s
- New tasks healthy before old tasks drained.

### 7.2 Blue/green (recommended later)

- CodeDeploy ECS for blue/green with automated rollback on alarms. Not mandatory in M9; design should not block it.

### 7.3 Graceful shutdown requirements (must-have)

On **SIGTERM:**

1. Stop accepting new connections
2. Allow in-flight streams to finish within configured drain window
3. Flush final writes to DynamoDB (M7) and finalize quotas (M8)
4. After drain window: close remaining connections politely

---

## 8. CI/CD Integration (Build → Push → Deploy)

### 8.1 ECR repositories (Terraform)

- `ecr/chat-api`, `ecr/chat-worker`, (optional) `ecr/web` if SSR on ECS
- Enable: image scanning, lifecycle policy (keep last N images)

### 8.2 Deployment mechanism (simple and effective)

- **GitHub Actions:** Build images → push to ECR with tag = git SHA
- **Update ECS service:** `aws ecs register-task-definition` + `aws ecs update-service`
- Task definition template in repo or generated in pipeline
- Later: CDK pipelines, CodePipeline, or Argo (if ever migrating)

---

## 9. Terraform Implementation (Compute Stack)

### 9.1 New module(s)

- **modules/ecr**
- **modules/alb**
- **modules/ecs-cluster**
- **modules/ecs-service**
- **modules/autoscaling**
- **modules/observability-ecs-alb** (alarms baseline)

### 9.2 Live stack layout

```
infra/terraform/live/{dev,staging,prod}/compute/
  ecr.tf
  alb.tf
  ecs.tf
  autoscaling.tf
  outputs.tf
```

### 9.3 Key inputs

- Subnet IDs from M3 (public for ALB, private-app for ECS)
- Security group IDs
- Domain/cert ARNs from M5 (regional cert for ALB)
- Table names from M7
- Redis endpoint + auth secret from M8

### 9.4 Key outputs

- ALB DNS name
- Target group ARN
- ECS cluster ARN
- Service names
- ECR repo URLs

---

## 10. Configuration Management in ECS

### 10.1 Env vars (non-secret)

- DDB_CONVERSATIONS_TABLE, DDB_MESSAGES_TABLE, DDB_REQUESTS_TABLE
- REDIS_HOST, REDIS_PORT
- LOG_LEVEL, DEFAULT_MODEL
- MAX_CONCURRENT_STREAMS_PER_TASK

### 10.2 Secrets (Secrets Manager)

- REDIS_AUTH_TOKEN
- LLM_PROVIDER_API_KEY
- (Optional) JWT_JWKS_CACHE_SALT etc.

ECS injects secrets at runtime. No secrets in Terraform state other than secret ARNs.

---

## 11. Observability & Alarms (M9 baseline)

### 11.1 ALB alarms

- HTTPCode_Target_5XX_Count > threshold
- TargetResponseTime p95 > threshold
- UnHealthyHostCount > 0 sustained

### 11.2 ECS alarms

- CPU > 80% sustained
- Memory > 80% sustained
- Task count below desired (service not stable)

### 11.3 Log groups

- `/ecs/chat-api`, `/ecs/chat-worker`
- **Retention:** dev 7–14 days; prod 14–30 days (tune)

---

## 12. Deep SSE Considerations (what usually breaks in production)

### 12.1 Connection limits

- Each task: memory per connection, file descriptors. Ensure container ulimits aren’t too low (Fargate defaults; app must be efficient).

### 12.2 Ping to avoid idle timeout

- **SSE “ping” event every 10–15 seconds is mandatory.**

### 12.3 Scale-in disruption

- Scale-in can kill tasks with live streams. **Mitigations:** conservative scale-in cooldowns; preStop drain (SIGTERM); cap stream duration; optionally disable aggressive scale-in during peak.

---

## 13. Security Hardening (Compute Layer)

### 13.1 Task runtime hardening

- Run as non-root
- Read-only FS where possible
- Slim images (no shell tools)
- Drop Linux capabilities where supported
- Restrict outbound: prefer VPC endpoints; NAT only if required (e.g. OpenAI)

### 13.2 IAM hardening

- **Execution role:** minimal (ECR pull, logs, secrets if needed)
- **Task role:** minimal (DDB, Redis, S3 only)
- Region restriction via IAM conditions if desired

---

## 14. Testing & Validation (M9 gate)

### 14.1 Smoke tests (after deploy)

- `/ready` returns 200 behind ALB
- Auth-required endpoints reject missing JWT
- Chat endpoints work end-to-end with DynamoDB + Redis
- Streaming works through ALB (and CloudFront if in front)

### 14.2 Load test “first prove”

- 500 concurrent streams for 10 minutes
- No 5xx spikes; no Redis timeout spikes
- ECS scales up/down without thrashing

---

## 15. Definition of Done (M9 acceptance checklist)

- [ ] ALB deployed in public subnets with TLS listener
- [ ] ECS cluster + chat-api service in private subnets (no public IP)
- [ ] chat-api registered behind target group; health checks pass
- [ ] CloudFront routes api.example.com to ALB origin (or ready to)
- [ ] Secrets injected from Secrets Manager (no hardcoded secrets)
- [ ] Autoscaling configured for chat-api (RequestCountPerTarget + CPU/mem)
- [ ] Rolling deployments work; graceful shutdown drains streams
- [ ] CloudWatch logs and alarms exist for ALB/ECS
- [ ] Runbooks documented: deploy/rollback, alarms, scaling adjustments
