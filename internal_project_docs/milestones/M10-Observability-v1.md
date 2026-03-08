# M10 — Observability v1 (Logs, Metrics, Traces, Dashboards, Alerts, SLO Reporting) — Technical Design v1

M10 makes the platform operable at scale. After this milestone you can answer, quickly and confidently:

- “Is the system healthy?”
- “Which tenant/user is affected?”
- “Is the issue AWS infra, our code, or the LLM provider?”
- “What changed? Can we roll back safely?”
- “Are we meeting SLOs and burning error budget?”

M10 is built to support streaming workloads (SSE), multi-tenant traffic, and the realities of external model providers.

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- **Structured logging** with redaction policy (no prompt/PII leaks).
- **Metrics** for golden signals (latency, traffic, errors, saturation) + business metrics (tokens, streams).
- **Distributed tracing** with OpenTelemetry, correlated to logs and metrics.
- **Dashboards** that make health obvious in &lt; 30 seconds.
- **Alerting:** actionable, low-noise, severity-based, with runbooks.
- **SLO/SLI measurement** aligned with M0 (availability, TTFT, stream stability).

### Non-Goals (later milestones)

- Full SIEM integration and org-wide compliance reporting
- Advanced anomaly detection
- Multi-region aggregated observability (M17)
- Cost optimization dashboards (M18)

### Outcomes

- One-click dashboards per environment: dev/staging/prod.
- Alerts routed via SNS (and optionally PagerDuty/Slack) with clear ownership.
- Traces visible in X-Ray (or another backend) with consistent correlation IDs.
- SLO burn charts and error budget alarms.

---

## 1. Observability Architecture (AWS-native + OpenTelemetry)

### Recommended base stack (v1)

| Component | Use |
|-----------|-----|
| **CloudWatch Logs** | Structured logs |
| **CloudWatch Metrics** | Custom + AWS service metrics |
| **CloudWatch Dashboards** | Overview + deep dives |
| **CloudWatch Alarms + SNS** | Alert routing |
| **AWS X-Ray** | Tracing (via OpenTelemetry / ADOT) |
| **ADOT Collector** | Sidecar container in ECS tasks (recommended) |

Single pane without too many moving parts.

### Optional expansions (compatible later)

- Amazon Managed Grafana for dashboards
- Amazon Managed Prometheus for Prometheus-native scraping
- Kinesis Firehose → S3 / OpenSearch for long-term log analytics

---

## 2. Correlation Standards (everything must link)

### 2.1 IDs and headers (contract)

| Header / ID | Rule |
|-------------|------|
| **X-Request-Id** | Generated at edge or API; returned on all responses |
| **traceparent** (W3C) | Propagated for distributed tracing |
| **X-Tenant-Id** | Do not accept from client; derived from JWT claim |
| **X-Conversation-Id** | Internal correlation (safe to echo) |

### 2.2 Generation rules

- If request arrives without X-Request-Id, API generates UUIDv4.
- API returns X-Request-Id always (including errors).
- **Tracing:** create trace/span for request; attach request_id, tenant_id (or hash), conversation_id as attributes.

### 2.3 Correlating logs ↔ traces ↔ metrics

All three must include: **env**, **service**, **version** (git SHA), **request_id**, **tenant_id_hash** (not raw if sensitive), **conversation_id** (optional), **user_id_hash** (optional, hashed).

---

## 3. Logging (Structured JSON + Redaction)

### 3.1 Logging policy (mandatory)

- **Never** log raw message content (prompts, assistant responses) in prod by default.
- **Never** log secrets, tokens, Authorization headers.
- Use “debug sampling” only in dev/staging behind explicit flags.

### 3.2 Log schema (standard across services)

Every log line is JSON:

```json
{
  "ts": "2026-02-08T12:34:56.789Z",
  "level": "INFO|WARN|ERROR",
  "env": "dev|staging|prod",
  "service": "chat-api|chat-worker|web",
  "version": "gitsha",
  "request_id": "uuid",
  "trace_id": "hex",
  "span_id": "hex",
  "tenant_id_hash": "hash",
  "user_id_hash": "hash",
  "conversation_id": "conv_...",
  "event": "http_request|provider_call|ddb_write|rate_limit_denied|...",
  "route": "/v1/chat/stream",
  "method": "POST",
  "status": 200,
  "latency_ms": 1234,
  "details": { "safe_kv": "only non-sensitive" }
}
```

### 3.3 Redaction rules

- **Drop/replace:** prompt/response text; emails/phones in metadata; Authorization header.
- **Keep:** message sizes (chars/tokens), timing, provider model name (safe).

### 3.4 Log routing and retention

- **Log groups:** `/ecs/prod/chat-api`, `/ecs/prod/chat-worker`
- **Retention:** dev 7–14 days; staging 14 days; prod 30 (or 90) days.
- **Optional:** subscription filter → Firehose → S3 for long retention.

---

## 4. Metrics (Golden Signals + Business/Cost Signals)

### 4.1 Service metrics (Golden Signals)

| Signal | Metrics |
|--------|---------|
| **Traffic** | http_requests_total{route,method,status} |
| **Errors** | http_errors_total{route,status}; provider_errors_total{provider,code}; stream_errors_total{reason} |
| **Latency** | http_latency_ms{route} (p50/p95/p99); ttft_ms{model,provider}; stream_duration_ms{route} |
| **Saturation** | active_streams (gauge); redis_latency_ms, redis_timeouts_total; ddb_throttles_total; ECS CPU/memory |

### 4.2 Business / FinOps metrics (high leverage)

- tokens_in_total{tenant} / tokens_out_total{tenant}; tokens_total (aggregate)
- requests_per_tenant_total
- quota_denied_total
- rate_limit_denied_total{scope=bucket}

Essential for abuse detection and paid tiers later.

### 4.3 How to emit custom metrics (recommended)

- **Option A:** CloudWatch **Embedded Metric Format (EMF)** from app logs — simple and robust on ECS (recommended for v1).
- **Option B:** OpenTelemetry metrics → CloudWatch (more advanced).

### 4.4 Cardinality control (critical)

- **Do not** use raw user_id as a metric label.
- For **tenant:** only emit tenant dimension for small allowlist (top tenants), **or** hashed tenant + sampling, **or** keep tenant in logs and derive analytics later.

---

## 5. Distributed Tracing (OpenTelemetry + X-Ray)

### 5.1 Tracing objectives

- For any chat request, see: auth verify → Redis checks → DynamoDB writes/queries → provider call latency → streaming loop duration.
- Identify root cause: “provider slow”, “Redis timeouts”, “DynamoDB throttling”, “app CPU”.

### 5.2 OTel in ECS (recommended pattern)

- **ADOT Collector** as sidecar in same task.
- App exports **OTLP** to localhost:4317.
- Collector exports to: **AWS X-Ray** (traces); CloudWatch (optional metrics). Keep logs separate.

### 5.3 Span naming and attributes (standard)

**Span names:** http.server, auth.verify_jwt, redis.rate_limit, redis.concurrency_acquire, ddb.put_message, ddb.update_request, provider.stream_call, sse.stream_loop

**Span attributes:** request_id, tenant_id_hash, conversation_id, provider, model, route, status_code, error.code (your taxonomy)

### 5.4 Sampling strategy

| Env | Sampling |
|-----|----------|
| dev | 100% |
| staging | 20–50% |
| prod | 1–10% baseline + **tail sampling for errors and slow traces:** keep 100% of traces with status 5xx, provider_error, latency &gt; p95 threshold |

X-Ray / OTel collector supports “keep errors” sampling rules.

---

## 6. Dashboards (what operators see)

M10 delivers **3 dashboards per env:**

### 6.1 “Service Overview” (first screen)

- RPS by route (stacked)
- 4xx and 5xx rates
- Latency p50/p95/p99 for /v1/chat and /v1/chat/stream
- Active streams (gauge/line)
- Provider TTFT p95
- Redis timeouts + latency p95
- DynamoDB throttles
- ECS desired vs running tasks

### 6.2 “Streaming Health”

- Streams started vs completed vs errored
- Stream error reasons
- Average stream duration
- “Ping gap” (if heartbeat timing tracked)
- Scale events overlay (task count changes)

### 6.3 “Dependencies”

- Redis: CPU, memory, evictions, connections
- DynamoDB: consumed capacity, throttles, latency
- ALB: TargetResponseTime, 5xx
- NAT bytes out (if external providers)

---

## 7. Alerting (Actionable, low-noise, severity-based)

### 7.1 Severity levels

| Level | Meaning |
|-------|---------|
| **SEV1** | User-facing outage or large-scale impact (page) |
| **SEV2** | Partial degradation (notify + investigate) |
| **SEV3** | Early warning / trend (ticket) |

### 7.2 Alarm design principles

Page only when: sustained breach **and** likely real customer impact **and** clear ownership and runbook exist.

### 7.3 Core alarms (recommended)

| Area | SEV1 | SEV2 / SEV3 |
|------|------|-------------|
| **API** | 5xx_rate &gt; 2% for 5 min (exclude 499-like disconnects if classified); p95_latency(chat_stream) &gt; SLO for 10 min | overloaded_rejections increasing; TTFT p95 &gt; threshold |
| **ALB** | UnHealthyHostCount &gt; 0 for 5 min | TargetResponseTime p95 high |
| **Redis** | Unavailable / failover stuck (connection errors spike) | Evictions &gt; 0 sustained; memory &gt; 85%; connections unusually high (SEV3) |
| **DynamoDB** | Throttles sustained &gt; 0 | Latency p95 high |
| **Quota/rate** | — | Spike in rate-limit denials (SEV3); quota denials spike (SEV3) |

### 7.4 Alert routing

- **SNS topics:** prod-sev1-alerts, prod-sev2-alerts, staging-alerts
- **Subscriptions:** email initially; later PagerDuty/Slack webhook
- **Each alarm includes:** summary, links to dashboard, runbook link, request_id sample query pattern

---

## 8. SLO/SLI Implementation (M0 compliance)

### 8.1 Availability SLI

- **Good:** HTTP 2xx/3xx. **Bad:** HTTP 5xx (and optionally 429 for paid tiers).
- Measure separately for /v1/chat and /v1/chat/stream.
- **SLO target:** 99.9% monthly (M0).

### 8.2 Latency SLI

- **Platform overhead:** time to first byte + internal spans excluding provider.
- **End-to-end:** TTFT and completion times including provider.

### 8.3 Stream stability SLI

- **Stream completion ratio:** completed / started.
- **Segment by reason:** client_disconnect, platform_error, provider_error, timeout.

### 8.4 Error budget burn alerts (advanced)

- Multi-window burn rate: fast (e.g. 5m) + slow (e.g. 1h).
- Alert if both exceed threshold → reduces flapping and catches real incidents.

---

## 9. Implementation in Code (what gets instrumented)

### 9.1 Middleware instrumentation (chat-api)

- Assign request_id; start trace span.
- Capture: route, status, latency, tenant_id_hash, stream vs non-stream classification.

### 9.2 Streaming instrumentation

- **Counters:** streams_started_total, streams_completed_total, streams_errored_total{reason}.
- **Gauge:** active_streams — increment on acquire (and Redis in M8), decrement in finally.
- **TTFT:** capture request start timestamp and first token timestamp; emit ttft_ms.

### 9.3 Dependency spans/metrics

- **Redis:** latency + timeouts
- **DynamoDB:** latency + errors + conditional check failures (idempotency debugging)
- **Provider:** latency + errors by provider/model

### 9.4 Worker instrumentation

- job latency, retries, DLQ count (M12)

---

## 10. Terraform Implementation (Observability Modules + Stacks)

### 10.1 New module: `modules/observability-core`

Creates:

- CloudWatch Log Groups (service-level) + retention
- CloudWatch Dashboards (JSON)
- SNS topics + subscriptions (env/severity)
- CloudWatch Alarms: ECS CPU/mem, ALB 5xx + latency, Redis health, DynamoDB throttles
- KMS key for log group encryption (optional but recommended)

### 10.2 Tracing resources

- X-Ray sampling rules (optional)
- IAM permissions for tasks to emit traces (if needed; often collector handles)

### 10.3 Live stack layout

```
infra/terraform/live/{dev,staging,prod}/observability/
  logs.tf
  dashboards.tf
  alarms.tf
  sns.tf
  outputs.tf
```

**Outputs:** dashboard URLs, SNS topic ARNs, log group names, alarm ARNs.

---

## 11. Runbooks (M10-level operational docs)

### 11.1 Runbook: “5xx spike”

1. Check Service Overview: one route or all? ALB unhealthy hosts? Redis/DDB throttles?
2. Inspect sample trace for failing requests.
3. If recent deploy: compare version in logs; rollback ECS to previous task definition.

### 11.2 Runbook: “TTFT high”

- Compare provider latency vs platform overhead spans.
- **If provider high:** mark provider incident; optional failover later.
- **If platform high:** check Redis latency/timeouts, DDB latency/throttles, CPU/memory saturation.

### 11.3 Runbook: “stream disconnects”

- Mostly client_disconnect? (likely normal.)
- **If platform_error rises:** check scale-in events, app shutdown/draining, ALB idle timeouts (ensure pings).
- **If provider_error rises:** provider incident or API key/rate limits.

---

## 12. Definition of Done (M10 acceptance checklist)

- [ ] Structured JSON logs across chat-api and chat-worker with request_id and redaction policy
- [ ] Custom metrics for: latency p95, 5xx rate, active_streams, TTFT p95, provider errors/latency, redis timeouts/latency, dynamodb throttles
- [ ] Traces visible end-to-end (request → Redis → DDB → provider)
- [ ] Dashboards exist for: overview, streaming health, dependencies
- [ ] Alerts configured with severity routing and runbooks linked
- [ ] SLO/SLI measurement implemented (at least availability + TTFT + stream stability)
- [ ] Retention policies set; prod logs not leaking PII/prompt text
