# M12 — Async Jobs Platform v1 (SQS + Workers + DLQ + Retries + Job Tracking) — Technical Design v1

M12 moves anything slow, expensive, or bursty off the request path so your chat API stays fast and stable under load. It introduces a reliable, observable, multi-tenant job system with: SQS queues (encrypted), worker services (ECS/Fargate), DLQs + redrive, idempotency + exactly-once effects, job tracking (DynamoDB), autoscaling on backlog, and operational runbooks.

This milestone is a big “professional platform” unlock.

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- Provide a **generic job framework** that supports multiple job types.
- **Guarantee safe semantics** under AWS realities (at-least-once delivery): no duplicate side effects (idempotent processing); safe retries with exponential backoff; poison-message isolation via DLQ.
- **Job status visibility** for users/admins: created → queued → running → succeeded/failed/dead-lettered.
- **Elastic scaling:** workers scale on SQS backlog.
- **Multi-tenant isolation + quotas** at enqueue time.

### Non-Goals (later)

- Workflow DAGs / orchestration (Step Functions) (later if needed)
- Multi-region job replication (later)
- Complex priority scheduling across many queues (v2)

### Outcomes

- **Terraform deploys:** SQS queue(s) + DLQ(s) + KMS; DynamoDB jobs table + indexes; ECS worker service + autoscaling; alarms and dashboards for queues + workers.
- **API supports:** create job (internal and/or user-facing); get job status / list jobs; cancel job (best-effort).
- **At least 2 real job types** implemented end-to-end.

---

## 2. What Goes Into Jobs (examples)

Jobs are for anything that should **not** block /v1/chat/stream:

| Category | Examples |
|----------|----------|
| **LLM-ish** | conversation_title_generate, conversation_summarize, moderation_async, export_conversation_pdf (later) |
| **Platform** | usage_aggregate_hourly (tenant cost tracking), cleanup_expired_requests, reindex_tenant (future RAG) |

**In M12, implement at least:**

- **conversation_title_generate** (fast win)
- **usage_aggregate_hourly** or **conversation_summarize** (proves reliability + scheduling hooks)

---

## 3. High-Level Architecture

### Components

| Component | Role |
|-----------|------|
| **chat-api** (producer) | Validates request, checks quotas/permissions, creates job record, enqueues message |
| **SQS Queue** (transport) | At-least-once delivery, long polling |
| **chat-worker** (consumer) | Processes messages, updates job status, writes outputs (DDB/S3), retries as needed |
| **DLQ** | Poison messages after max receives |
| **DynamoDB Jobs Table** | System of record for job state + idempotency + results pointer |
| **CloudWatch/X-Ray** | Tracing + logs + metrics (build on M10) |

### Queue topology (recommended v1)

- **jobs-default** (standard queue)
- **jobs-default-dlq**

Optional (if you need strict priorities): jobs-high + DLQ, jobs-low + DLQ. Start with **one queue** unless you truly need priority separation.

---

## 4. Delivery Semantics (the “think deep” core)

SQS is **at-least-once**, so duplicates happen. The platform must provide **exactly-once effects** via idempotency in the worker.

### 4.1 Exactly-once effects: how

- Each job has a stable **job_id**.
- **Worker processing** guarded by conditional update: if job is already SUCCEEDED (or terminal), worker ACKs message; if job is RUNNING under another worker, worker defers (rare).
- Any **side effect** (writing results) is keyed by job_id so repeated attempts overwrite safely or no-op.

### 4.2 The job state machine

**States:** CREATED → QUEUED → RUNNING → SUCCEEDED | FAILED | CANCELLED | DEAD_LETTERED

**Transitions:**

| From | To | Trigger |
|------|-----|---------|
| CREATED | QUEUED | API after SQS send |
| QUEUED | RUNNING | Worker claims |
| RUNNING | SUCCEEDED \| FAILED | Worker completes |
| RUNNING \| QUEUED | DEAD_LETTERED | SQS DLQ (maxReceiveCount exceeded) |
| — | CANCELLED | API cancel (best-effort) |

---

## 5. Data Model (DynamoDB Job Tracking)

### Table: chat_jobs

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}` |
| **SK** | `JOB#{job_id}` |
| **Attributes** | job_id, tenant_id, user_id, type, status, created_at, updated_at, queued_at, started_at, finished_at, attempt, max_attempts, priority (optional), idempotency_key (optional), input_ref, result_ref, error_code, error_message_safe, trace_id, request_id, ttl (optional) |

### Indexes

| GSI | Purpose |
|-----|---------|
| **GSI1** | List jobs by user/time: GSI1PK = `TENANT#{tenant_id}#USER#{user_id}`, GSI1SK = `CREATED#{created_at}#JOB#{job_id}` |
| **GSI2** (optional) | Find by idempotency: GSI2PK = `TENANT#{tenant_id}#IDEMP#{idempotency_key}`, GSI2SK = `JOB#{job_id}` |

M12 should include at least **GSI1**. Add GSI2 if “create job is idempotent.”

---

## 6. Message Envelope (SQS payload contract)

SQS message body JSON (keep &lt; 256KB; ideally far smaller):

```json
{
  "job_id": "uuid",
  "tenant_id": "t_123",
  "user_id": "u_abc",
  "type": "conversation_title_generate",
  "created_at": "2026-02-08T00:00:00Z",
  "attempt": 0,
  "trace": {
    "request_id": "uuid",
    "traceparent": "00-...."
  },
  "input": {
    "conversation_id": "conv_123",
    "message_ids": ["..."]
  }
}
```

**Large payload rule:** If input could become big, store in S3: `s3://<bucket>/jobs/<tenant_id>/<job_id>/input.json`; message contains `"input_ref": {"s3_key": "...", "sha256": "..."}`.

---

## 7. Producer Path (chat-api enqueue flow)

### 7.1 API endpoints (v1)

| Method | Path | Purpose |
|--------|------|---------|
| POST | /v1/jobs | Create job (admin/internal or tenant-scoped) |
| GET | /v1/jobs/{job_id} | Get job status |
| GET | /v1/jobs?limit=...&cursor=... | List jobs |
| POST | /v1/jobs/{job_id}/cancel | Cancel (best-effort) |

User-facing shortcut: **POST /v1/conversations/{id}/title:generate** → creates job and returns job_id.

### 7.2 Enqueue algorithm (safe + simple)

1. Validate auth/tenant boundary (M4)
2. Validate job type, input schema, and plan permissions
3. (Optional) Idempotency: if Idempotency-Key provided, query GSI2; if exists return existing job
4. Write chat_jobs item with status **CREATED**
5. Send message to SQS
6. Update job status to **QUEUED** with queued_at

**Failure handling:** If SQS send fails after job record created: retry send in API; if still fails: mark job FAILED (enqueue_failed) or leave CREATED and rely on a **periodic “re-enqueue sweeper”** job (recommended for robustness).

**Recommended extra:** Add a tiny scheduled worker that scans for CREATED jobs older than N minutes and enqueues them (safety net).

---

## 8. Consumer Path (chat-worker processing loop)

### 8.1 Worker poll strategy

- **Long polling:** WaitTimeSeconds=20
- **Batch size:** 5–10 messages
- **Concurrency:** controlled (don’t spawn unlimited tasks)

### 8.2 Per-message processing (exactly-once effects)

| Step | Action |
|------|--------|
| 1 | Parse envelope; validate required fields |
| 2 | Load job record: if status terminal → delete SQS message (ACK) and stop |
| 3 | **Claim job:** conditional update: set status=RUNNING, started_at=now, increment attempt; condition: status IN (QUEUED, CREATED) and attempt &lt; max_attempts. If condition fails → ACK and stop |
| 4 | Execute handler by type |
| 5 | **On success:** store result; set status=SUCCEEDED, finished_at, result_ref; delete SQS message |
| 6 | **On transient failure:** set status=QUEUED (or RETRY_WAIT); do not delete message (visibility timeout) or ChangeMessageVisibility for backoff |
| 7 | **On permanent failure:** set status=FAILED; delete SQS message (or allow DLQ per policy) |

### 8.3 Backoff strategy (recommended)

Use **ChangeMessageVisibility** for transient errors:

| Attempt | Visibility |
|---------|------------|
| 1 | 10s |
| 2 | 30s |
| 3 | 2m |
| 4 | 5m |
| 5 | 15m → then fail or allow DLQ |

### 8.4 DLQ policy

- **SQS redrive:** maxReceiveCount = 5–8 (tune); after that message goes to DLQ.
- **When message hits DLQ:** separate “dlq-processor” job or manual runbook marks job **DEAD_LETTERED** and stores DLQ receipt metadata.
- **Alarm:** DLQ depth &gt; 0.

### 8.5 Visibility timeout

- Set queue **VisibilityTimeout** to exceed max expected job runtime (or extend in worker).
- For LLM jobs: usually &lt; 2 minutes; set timeout to 5 minutes; worker extends periodically if job runs long.

---

## 9. Job Handlers (framework + two real jobs)

### 9.1 Handler interface

Each job type implements:

- **validate(input)** → validated_input
- **execute(ctx, input)** → result_ref
- **is_transient_error(e)** → bool

### 9.2 Job: conversation_title_generate

- **Input:** conversation_id
- **Process:** fetch last N messages from DynamoDB (M7); call provider to generate title; store title into chat_conversations + update updated_at
- **Output:** result_ref = {conversation_id, title}

### 9.3 Job: usage_aggregate_hourly (or conversation_summarize)

- **Option A (usage):** aggregate usage from message metadata (token counts) for last hour/day; write to tenant_usage_daily (M12 or reserve for M15).
- **Option B (summarize):** fetch messages, create summary, store in conversation metadata or separate table.

Pick one based on roadmap; both validate the framework.

---

## 10. Autoscaling Workers (ECS scaling on SQS backlog)

### 10.1 Scaling signal

- **ApproximateNumberOfMessagesVisible** (backlog)
- Optionally **ApproximateAgeOfOldestMessage**

### 10.2 Target tracking (recommended)

- **Target:** e.g. 50 visible messages per worker task
- **Min tasks:** dev 0–1, staging 1–2, prod 2–4
- **Max tasks:** prod 50+ (budget-driven)
- **Cooldowns:** scale-out 60–120s; scale-in 300–600s

### 10.3 Priority queues (optional)

If you add jobs-high, pin a small worker pool to it.

---

## 11. Security (IAM + encryption + network)

### 11.1 SQS encryption

- SSE-KMS with CMK; KMS policy allows only relevant roles.

### 11.2 IAM policies

| Role | Permissions |
|------|-------------|
| **chat-api task** | sqs:SendMessage on jobs queue; dynamodb:PutItem/UpdateItem/GetItem/Query on chat_jobs |
| **chat-worker task** | sqs:ReceiveMessage/DeleteMessage/ChangeMessageVisibility/GetQueueAttributes; dynamodb:GetItem/UpdateItem/Query on chat_jobs; access to messages/conversations tables; Secrets Manager (LLM keys); optional S3 for payload/results |

### 11.3 Network

- SQS is public AWS API; workers in private subnets need NAT egress **or** VPC interface endpoint for SQS (optional; reduces NAT).

---

## 12. Observability Additions (build on M10)

### 12.1 Metrics (must-have)

- jobs_enqueued_total{type}, jobs_started_total{type}, jobs_succeeded_total{type}, jobs_failed_total{type,reason}
- jobs_duration_ms{type} p95, jobs_queue_delay_ms{type} (started_at − queued_at)
- jobs_retried_total{type}, dlq_messages_total
- worker_poll_latency_ms, worker_batch_size, worker_errors_total

### 12.2 Alarms (must-have)

| Alarm | Severity |
|-------|----------|
| DLQ visible messages &gt; 0 for 5 min | SEV2/SEV1 |
| Age of oldest message &gt; threshold (e.g. 10–15 min) | SEV2 |
| Backlog growth sustained | SEV3 |
| Worker running tasks &lt; desired | SEV2 |
| Job failure ratio &gt; threshold | SEV2 |

### 12.3 Tracing

- Propagate **traceparent** from producer into SQS envelope; worker starts trace/span linked to it (or correlation via request_id). Makes async chains debuggable.

---

## 13. Terraform Implementation (Modules + Live Stacks)

### 13.1 New module: modules/async-jobs

- SQS queue + DLQ + KMS; redrive policy; queue alarms (backlog, age, DLQ); optional VPC endpoint for SQS.

### 13.2 New module: modules/jobs-table

- chat_jobs table: on-demand billing, PITR, SSE-KMS, TTL optional.

### 13.3 Compute updates

- Update chat-worker ECS: env (JOBS_QUEUE_URL, JOBS_TABLE_NAME, ENV); secrets (provider keys). Attach autoscaling policies based on SQS metrics.

### 13.4 Live stack layout

```
infra/terraform/live/{dev,staging,prod}/data/
  jobs_table.tf
  sqs_jobs.tf

infra/terraform/live/{dev,staging,prod}/compute/
  worker_service.tf   # autoscaling + task def env/secrets
```

---

## 14. Local Development & Testing

### 14.1 Local queue emulation

- **LocalStack** (SQS + DynamoDB) or **ElasticMQ** for SQS + DynamoDB (lighter). In docker-compose, add local SQS emulator and wire worker.

### 14.2 Tests

- **Unit:** handler validation + execute + error classification; idempotent job claiming logic.
- **Integration:** enqueue → worker consumes → SUCCEEDED; transient failure → retry + backoff; poison → DLQ and job DEAD_LETTERED.
- **Load (small):** enqueue 10k small jobs; validate throughput and backlog drain.

---

## 15. Operational Runbooks (M12 required)

| Runbook | Actions |
|---------|---------|
| **DLQ triage** | Alarm: DLQ has messages. Inspect message body; find job by job_id; determine bug vs bad input vs transient; fix + redeploy or redrive DLQ → main queue |
| **Stuck jobs** | Check AgeOfOldestMessage; worker tasks/CPU/mem; visibility timeout; handler extends visibility for long jobs |
| **Retry storm / provider** | Detect jobs_retried_total spike; reduce worker max; circuit breaker (fail fast) if provider down |

---

## 16. Definition of Done (M12 acceptance checklist)

- [ ] SQS queue + DLQ deployed with encryption, redrive policy, alarms
- [ ] DynamoDB chat_jobs deployed with PITR + encryption + indexes
- [ ] API can create jobs and returns job_id; idempotency supported (optional but recommended)
- [ ] Worker consumes jobs reliably: conditional claim prevents double-processing; retries with backoff; terminal states recorded
- [ ] DLQ behavior verified end-to-end
- [ ] Worker autoscaling on backlog works and doesn’t thrash
- [ ] Observability: dashboards/alerts for backlog, age, DLQ, job success rate
- [ ] At least two real job types implemented (title generation + one more)
