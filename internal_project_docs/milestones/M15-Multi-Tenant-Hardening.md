# M15 — Billing & Metering v1 (Accurate Usage Accounting, Plans, Quotas, Invoicing Foundations) — Technical Design v1

M15 turns your chatbot into a real product: you can measure usage accurately (tokens, requests, storage, jobs), enforce plans/quotas, and generate invoice-ready usage summaries. This milestone is careful about correctness under retries, streaming, tool calls, async jobs, and RAG—because billing breaks trust instantly if it’s wrong.

M15 builds on: M7 (durable messages), M8 (quotas), M10 (metrics), M12 (jobs), M13 (tools), M14 (RAG).

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- Define a **canonical usage model** and record **billable events:** chat tokens (input/output), streaming sessions, tool calls (count + cost units), async jobs (count + runtime), RAG (ingestion bytes, embedding tokens, retrieval calls), storage (uploaded bytes / indexed chunks).
- Implement a **billing-grade event pipeline:** deduplicated, idempotent, append-only; supports reconciliation and late events.
- Produce **tenant usage summaries** (daily/monthly) and expose via API.
- **Enforce quotas** tied to plans (building on M8 but now authoritative).
- **Invoice foundations:** monthly totals, per-unit breakdown, export to CSV/JSON; optionally Stripe “usage records” later (not required in v1).

### Non-Goals (later)

- Full payment processing + subscriptions (Stripe) (M16 or M15.5)
- Tax/VAT compliance, proration, credits/refunds (later)
- Multi-currency pricing (later)
- Chargeback/fraud pipeline (later)

### Outcomes

- Stable **“billable events”** schema stored durably.
- **Aggregation jobs** generating daily and monthly tenant statements.
- **Quotas** enforced from plan configuration + measured usage.
- **Admin tools** to audit and reconcile usage.

---

## 1. Metering Philosophy: “Events First, Aggregates Second”

### 1.1 Why events

Streaming, retries, tool calls, and async jobs produce complex usage. Log usage as **atomic events**, then aggregate.

### 1.2 Invariants

- **Append-only** event store (never overwrite historical usage).
- **Idempotent write:** same usage event cannot be counted twice.
- **Deterministic identifiers:** every event has a stable unique key.
- **Auditable:** trace invoice line item → underlying events → request_id/job_id/message_ids.

---

## 2. Billable Units (What you charge on)

Define a v1 pricing model that can evolve:

| Category | Units |
|----------|--------|
| **Chat** | tokens_in, tokens_out; optionally requests, stream_minutes |
| **Tool** | tool_calls by tool name; optional tool_cost_units |
| **Async jobs** | jobs_started by job type; job_runtime_ms or job_compute_units (optional) |
| **RAG** | rag_upload_bytes, rag_embedding_tokens, rag_retrieve_calls |
| **Storage** (optional v1) | stored_bytes per tenant per day (snapshot) or deltas |

**Recommendation:** Always **record** usage; billing engine can decide later which units are charged.

---

## 3. Event Schema (Canonical)

### 3.1 UsageEvent JSON (canonical)

```json
{
  "event_id": "string",
  "tenant_id": "t_123",
  "user_id": "u_abc",
  "event_type": "chat_completion|tool_call|job_run|rag_ingest|rag_retrieve",
  "occurred_at": "2026-02-08T12:00:00Z",
  "source": {
    "request_id": "uuid",
    "conversation_id": "conv_123",
    "message_id": "msg_...",
    "job_id": "job_...",
    "tool_name": "rag_retrieve",
    "provider": "openai|bedrock|...",
    "model": "..."
  },
  "usage": {
    "tokens_in": 123,
    "tokens_out": 456,
    "tool_calls": 1,
    "rag_embedding_tokens": 0,
    "rag_upload_bytes": 0,
    "rag_retrieve_calls": 0,
    "job_runtime_ms": 0
  },
  "cost": {
    "cost_units": 0,
    "currency": "USD",
    "unit_price_snapshot": { "optional": "..." }
  },
  "status": "final|estimated|adjustment",
  "metadata": {
    "env": "prod",
    "plan_id": "pro",
    "tags": ["..."]
  }
}
```

### 3.2 Event IDs (dedupe keys)

Deterministic event_id by source:

| Source | event_id pattern |
|--------|------------------|
| **Chat completion** | `chat#` + request_id |
| **Tool call** | `tool#` + request_id + `#` + step + `#` + tool_name |
| **Job** | `job#` + job_id + `#attempt#` + attempt |
| **RAG ingestion** | `rag_ingest#` + tenant_id + `#` + doc_id + `#v#` + version |
| **RAG retrieval** | `rag_retrieve#` + request_id + `#step#` + n |
| **Adjustment** | `adj#` + base_event_id + `#` + adj_seq |

---

## 4. Storage: DynamoDB Event Store + Aggregates

### 4.1 Table: usage_events

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}` |
| **SK** | `TS#{yyyyMMddHHmmss}#E#{event_id}` |
| **Attributes** | Full event document (or flattened); event_id as attribute |
| **GSI** | Lookup by event_id: GSI1PK = `EVENT#{event_id}`, GSI1SK = `TENANT#{tenant_id}` |
| **Write rule** | PutItem with condition `attribute_not_exists(GSI1PK)` or `attribute_not_exists(SK)` for dedupe |
| **Billing** | On-demand (PAY_PER_REQUEST) |
| **TTL** | Typically none (retention); archive to S3 later if needed |

### 4.2 Aggregate tables (derived)

| Table | PK / SK | Purpose |
|-------|---------|---------|
| **tenant_usage_daily** | PK = `TENANT#{tenant_id}#DAY#{yyyyMMdd}`, SK = METRIC (or per-metric) | Fast “show usage” and daily statements |
| **tenant_usage_monthly** | PK = `TENANT#{tenant_id}#MONTH#{yyyyMM}` | Invoices, stable monthly totals |

**Attributes:** tokens_in, tokens_out, tool_calls, rag_embed_tokens, etc.; cost_estimate_usd (optional); updated_at.

**Why separate:** Quick APIs; stable for invoices; cheaper than scanning raw events.

---

## 5. Event Production Points (where you emit usage)

| Path | When | Event type | Key fields |
|------|------|------------|------------|
| **Chat completion** (M6/M7) | Request completes | chat_completion | request_id, tokens_in/out, status=final. Streaming: only final billable; abort → partial or estimated then adjust |
| **Tool calls** (M13) | Each tool call | tool_call | tool name, step, latency, outcome; tokens if tool invokes LLM |
| **Jobs** (M12) | RUNNING (optional) / SUCCEEDED or FAILED | job_run | runtime, attempts |
| **RAG** (M14) | Upload complete, ingestion complete, retrieval | rag_ingest / rag_retrieve | rag_upload_bytes; rag_embedding_tokens, chunk counts; rag_retrieve_calls |

---

## 6. Aggregation Pipeline (Async, Reliable)

### 6.1 Aggregation job

- **Job types:** usage_aggregate_daily, usage_aggregate_monthly.
- **Schedule:** hourly incremental + daily finalization; monthly finalization at month end.
- **Implementation:** Worker reads events for time window; updates aggregates with idempotent logic.

### 6.2 Exactly-once aggregation effects

- **Checkpoint (v1):** Table **usage_agg_checkpoints** — PK = `TENANT#{tenant_id}`, SK = AGG#DAILY or AGG#HOURLY; last_evaluated_key, updated_at. Query events from cursor forward; update daily/monthly; store new cursor. **Risk:** crash mid-batch can cause double count if reprocessed.
- **Mitigation:** Small batches; commit cursor only after aggregate updates succeed.
- **Best-of-best (v1-friendly):** **Applied marker** table (e.g. usage_event_applied keyed by event_id). Aggregator conditional put; apply event only if marker insert succeeds → exactly-once.

**Recommendation:** Implement **applied marker** for enterprise-grade correctness.

---

## 7. Plans & Quotas (Authoritative)

### 7.1 Plan configuration model

**Table: tenant_plans**

- tenant_id, plan_id (free/pro/enterprise), effective_from
- **quotas:** tokens_per_day, requests_per_minute, rag_embed_tokens_per_day, rag_upload_bytes_per_day, tool_calls_per_day (by tool)
- **feature flags:** tools allowed, rag enabled, max concurrency

**Cache in Redis (M8)** for fast checks.

### 7.2 Enforcement points

| Layer | Role |
|-------|------|
| **Real-time** | Redis counters (M8) to block early |
| **Authoritative** | Usage events → aggregator computes daily totals; quota job can set “overage” state |

### 7.3 Overage policy

- **Soft limit (warn)** vs **hard cutoff (block)**.
- **v1:** Hard cutoff for free tier; soft warnings for paid tiers.

---

## 8. Usage APIs (Tenant + Admin)

### Tenant endpoints

- **GET /v1/billing/usage/daily?from=...&to=...**
- **GET /v1/billing/usage/monthly?from=...&to=...**
- **GET /v1/billing/limits** — plan quotas + current usage snapshot
- **GET /v1/billing/events?from=...&to=...&type=...** (optional; careful with volume)

### Admin endpoints (restricted)

- **GET /v1/admin/billing/tenant/{tenant_id}/usage**
- **POST /v1/admin/billing/reconcile** — enqueue reconciliation job

All enforce **tenant isolation and role checks** (M4).

---

## 9. Reconciliation & Adjustments

### 9.1 Adjustment events

- **Do not mutate** past events. Emit **event_type = adjustment** with negative or positive deltas.

### 9.2 Reconciliation job

- **Job: usage_reconcile** — recompute from authoritative sources (messages token fields, provider logs); compare with aggregates; emit adjustment events if discrepancy exceeds threshold.
- **v1 scope:** Adjustment mechanism + manual reconciliation hook; automated schedule later.

---

## 10. Security, Privacy, Compliance

### 10.1 Data minimization

- Usage events **do not** include raw prompts. Store only: token counts, tool names, doc IDs, request IDs.

### 10.2 Tenant visibility

- Tenants see only their aggregated metrics and their own events. Admin access audited.

### 10.3 Integrity controls

- Conditional writes to prevent duplicate event_id. KMS encryption; PITR enabled on event store and aggregates.

---

## 11. Observability (M10 integration)

### 11.1 Metrics

- usage_events_written_total{type}, usage_events_deduped_total
- usage_agg_lag_seconds, usage_agg_errors_total
- quota_enforced_total{quota_type}, overage_state_total

### 11.2 Alarms

- Aggregation lag &gt; threshold (e.g. 10–30 min)
- Event write failures &gt; threshold
- Reconcile job failures
- Sudden token spike (abuse detection)

---

## 12. Terraform Implementation (Modules + Live Stacks)

### New modules

| Module | Contents |
|--------|----------|
| **modules/billing-events** | DynamoDB usage_events + GSIs |
| **modules/billing-aggregates** | tenant_usage_daily, tenant_usage_monthly, usage_agg_checkpoints, optional usage_event_applied |
| **modules/billing-config** | tenant_plans (or part of tenant config store) |
| **modules/billing-observability** | Dashboards + alarms for aggregation and event pipeline |

### Compute updates

- **chat-api:** emit events on request completion and tool calls.
- **worker:** emit events on job completion and RAG ingestion stages.
- **Scheduled aggregation:** EventBridge Scheduler or cron-style worker triggers usage_aggregate_hourly job into M12 queue.

---

## 13. Testing Strategy (Billing correctness is sacred)

### Unit tests

- Deterministic event_id generation; dedupe logic (PutItem conditional); adjustment event arithmetic.

### Integration tests

- Chat request → event → aggregator updates daily/monthly; duplicate request replay → no duplicate event; tool call events counted once; RAG ingestion chain counted once.

### Property tests (high value)

- Random sequences of retries, partial streams, tool loops, job retries. Validate aggregate totals match sum of unique events.

---

## 14. Definition of Done (M15 acceptance checklist)

- [ ] Canonical UsageEvent schema implemented with deterministic event_id
- [ ] usage_events DynamoDB table created (encrypted, PITR, dedupe)
- [ ] Events emitted for: chat completions (final), tool calls, job runs, RAG ingestion + retrieval
- [ ] Aggregation pipeline produces daily and monthly tenant totals
- [ ] Aggregation is idempotent / exactly-once (checkpoint + applied marker recommended)
- [ ] Plan quotas stored and enforced (Redis fast path + authoritative aggregates)
- [ ] Usage APIs implemented for tenants; admin reconciliation hooks exist
- [ ] Observability for pipeline lag and failures, with alarms and runbooks
- [ ] Tests prove no double-charging under retries and streaming disconnect scenarios
