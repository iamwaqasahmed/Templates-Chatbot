# M11 — Load Testing + Performance Tuning Gate (Capacity Proof, Bottleneck Fixes, Scale Curves) — Technical Design v1

M11 is the milestone that turns “we think it scales” into “we can prove it scales.” You’ll build a repeatable load test harness, run realistic scenarios (including SSE), produce capacity curves, tune bottlenecks, and set hard deployment gates based on SLO/SLA targets from M0.

This is where you learn: how many concurrent streams per Fargate task, when Redis becomes a limiter, whether DynamoDB throttles, how provider latency impacts TTFT, and what autoscaling policies actually do under stress.

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- Create a **repeatable load-testing framework** (local + staging + prod-like).
- Define and run **realistic traffic models:** SSE streaming chat, non-stream chat, reads (list conversations/messages), retry storms/reconnects.
- **Measure:** throughput (RPS), concurrency (active streams), TTFT and stream completion rate, error rates and failure reasons, platform overhead (excluding provider latency).
- **Produce:** capacity numbers (“X tasks support Y streams at p95 TTFT &lt; Z”), autoscaling behavior analysis, tuning recommendations and applied fixes.
- **Add gates** so a deployment fails if it regresses performance materially.

### Non-Goals (later)

- Chaos testing (M17/DR milestone)
- Multi-region performance testing (M17)

### Outcomes

- **load/** directory in repo with k6 (recommended) or Locust scripts.
- A **staging test plan** + automated GitHub workflow to run tests.
- A **“Capacity Report”** document (repeatable template).
- **Updated autoscaling configs and service settings** based on results.

---

## 1. Test Environments (where tests run)

### 1.1 Environments

| Env | Use |
|-----|-----|
| **Local** (smoke only) | Validate scripts and correctness with stubbed provider |
| **Staging** (primary) | Realistic infra as prod (same VPC, ALB, ECS, Redis, DDB) |
| **Prod** (optional) | Only controlled canary tests |

### 1.2 Data strategy

- Use **dedicated test tenant(s) and users**.
- Pre-create: 1,000 conversations; 50,000 messages total (optional; for read tests).
- Ensure **TTL cleanup or tear-down script** to avoid unbounded growth.

---

## 2. Tooling Choice (Deep recommendation)

### Recommended: k6

- Great performance, simple JS scripts.
- Solid for HTTP; SSE with custom logic.
- Easy to run in CI and in ECS/Fargate as a one-off task.

### Alternative: Locust

- Good for Python-native devs; SSE handling is doable but more work.

**Recommendation:** k6 + a thin helper to handle SSE parsing robustly.

---

## 3. Workload Models (what you test)

Scenarios that match real usage, not synthetic “1000 RPS” only.

### Scenario A — “Interactive Chat Streaming” (core)

- **80% of traffic:** POST /v1/chat/stream
- **Think time:** 5–20s between messages
- **Concurrency target:** 500 → 2,000 active streams
- **Message sizes:** short prompts 70%, medium 25%, large 5%
- **Metrics:** p50/p95 TTFT, stream success ratio, average stream duration, platform vs provider error breakdown

### Scenario B — “Non-stream Chat Burst”

- **10% of traffic:** POST /v1/chat
- **Burst RPS target:** 50 → 300
- Validates request path, DDB writes, Redis checks under burst.

### Scenario C — “Read-heavy”

- **10%:** GET /v1/conversations, GET /v1/conversations/{id}/messages
- Tunes DynamoDB queries and optional caching.

### Scenario D — “Reconnect / Retry Storm”

- Simulate: client drops stream at 10–30% completion; reconnects using same Idempotency-Key.
- **Expected:** no duplicate assistant messages (M7), no concurrency leaks (M8), stable system, limited extra cost.

### Scenario E — “Abuse/Attack Pattern”

- Very high request rate from same IP/user.
- **Expected:** WAF blocks or app returns 429; platform stays healthy.

---

## 4. Success Criteria (Performance Gates)

Tie directly to **M0 SLOs**.

### 4.1 Core gates (staging)

At target concurrency **C_target** (e.g. 2,000 active streams):

| Area | Gate |
|------|------|
| **API availability** | ≥ 99.9% (platform-only errors) |
| **/v1/chat/stream** | p95 TTFT &lt; 2.5s (or chosen threshold); stream completion ratio ≥ 99.5% (excluding client disconnects) |
| **/v1/chat** | p95 latency &lt; 1.5s (platform overhead) |
| **Redis** | p95 command latency &lt; 10–15ms; timeouts ~0 |
| **DynamoDB** | Throttles 0 sustained |
| **ECS** | Memory &lt; 80% sustained; CPU not pegged (&gt;90% sustained indicates headroom issues) |

### 4.2 Degradation behavior gates

Under overload:

- System returns **429** (rate limit/quota) or **503 overloaded**, not random 500s.
- No cascading failure (Redis meltdown, DDB throttles, task crash loops).

---

## 5. Test Harness Design (repo + scripts)

### 5.1 Repo layout

```
load/
  README.md
  k6/
    common.js
    scenarios/
      stream_chat.js
      non_stream_chat.js
      read_heavy.js
      retry_storm.js
      abuse.js
  data/
    prompts_small.json
    prompts_medium.json
    prompts_large.json
  tools/
    seed_data.py
    cleanup_data.py
```

### 5.2 Seeding and cleanup

- **seed_data.py:** creates tenant/users; creates conversations and initial messages.
- **cleanup_data.py:** deletes test conversations/messages (or marks with TTL).

---

## 6. SSE Load Testing (the hard part)

### 6.1 What must be measured for streaming

- **TTFT:** time from request send to first `event: token`
- **Token rate:** optional (tokens/sec)
- **Stream completion:** `event: done` received
- **Disconnect reason:** timeout, server close, client cancel

### 6.2 SSE parsing requirements

- Parse lines: `event: <name>`, `data: <json>`.
- Handle **partial frames** correctly (TCP chunking).

### 6.3 k6 SSE approach

- k6 has no native SSE like a browser. Implement: HTTP request to stream endpoint; read response body incrementally (in k6 this is limited; workaround: websockets or small Go proxy).
- **Best practice for rigorous SSE testing:** Run a small **SSE load generator service** (Go or Node) that supports high-concurrency streaming reads; k6 drives it with “start stream” commands, or run the generator directly.

**Practical “best-of-the-best” design:**

- Add **load/generator/:** lightweight Go service that opens N SSE connections and reports metrics.
- Run it as an **ECS one-off task** in staging VPC (avoids internet variability).
- Eliminates test tool limitations and gives accurate streaming metrics.

---

## 7. Where to Run Load Tests (avoid misleading results)

### 7.1 Run inside the AWS VPC (recommended)

- Execute load generator as an **ECS Fargate task** in private subnets.
- **Why:** avoids public internet jitter; measures the platform, not the WAN.

### 7.2 Run from outside (optional)

- Useful for real-user experience.
- Separate results from “platform capacity results.”

---

## 8. Metrics Collection & Analysis (use M10 instrumentation)

### 8.1 Collect during tests

- CloudWatch dashboards pinned to test start time.
- **Export:** ALB TargetResponseTime; ECS CPU/mem; Redis metrics; DynamoDB throttles; custom metrics (active_streams, ttft_ms, streams_completed_total, provider_latency_ms).

### 8.2 Produce “Capacity Curves”

Plot:

- p95 TTFT vs concurrent streams
- stream completion ratio vs concurrent streams
- 5xx rate vs RPS
- Redis p95 latency vs ops/sec
- DynamoDB throttles vs write rate

**Result:** a table like:

| Tasks | Streams (SLO-compliant) |
|-------|---------------------------|
| 3 | 600 streams |
| 6 | 1,200 streams |
| 10 | 2,000 streams |

…with SLO compliance noted.

---

## 9. Bottleneck Diagnosis (what usually breaks)

### 9.1 Common bottlenecks and fixes

| Bottleneck | Fixes |
|------------|-------|
| **A) Too many streams per task → memory** | Lower MAX_CONCURRENT_STREAMS_PER_TASK; increase task memory; increase min task count; reduce gunicorn workers if needed |
| **B) ALB idle timeout / stream drops** | Ensure ping every 10–15s; verify ALB idle timeout and CloudFront behavior |
| **C) Redis latency/timeouts** | Lua scripts O(1); increase Redis node size or cluster mode; reduce per-request Redis ops (combine in one script) |
| **D) DynamoDB throttles** | Hot partition: adjust key design or sharding; on-demand helps but can still throttle; reduce writes / batch; use conditionals carefully |
| **E) Provider slow** | Timeouts; circuit breakers; optional fallback model later. Separate “platform overhead” from provider latency in reporting |

---

## 10. Autoscaling Tuning (prove scaling works)

### 10.1 Validate scaling triggers

- Does scaling occur when RequestCountPerTarget rises?
- Does it lag too much?
- Does scale-in kill active streams?

### 10.2 Recommended tuning patterns

- **Scale-out cooldown** small (60–120s)
- **Scale-in cooldown** larger (300–600s)
- **Minimum tasks** in prod ≥ 3 (or more from baseline usage)
- Consider **custom metric** scale on active_streams (most accurate)

### 10.3 Verify “no thrash”

- Run 60–90 minute soak with fluctuating load.
- Ensure tasks don’t oscillate every few minutes; ensure cost stays reasonable.

---

## 11. Performance Regression Gates (CI / release)

### 11.1 What to automate

- **Short performance suite** on PR or nightly in staging: 5–10 minutes, moderate concurrency (e.g. 200–500 streams).
- **Compare to baseline thresholds:** TTFT p95, 5xx rate, memory usage, stream completion ratio.
- If it regresses beyond tolerance → **fail build / block release**.

### 11.2 Baseline storage

- Store baseline numbers in repo (or S3): **load/baselines/staging.json**
- Update intentionally when improvements occur.

---

## 12. Deliverable: Capacity Report (template)

Create **docs/performance/capacity_report.md** containing:

- Test date/time, commit SHA, environment
- **Infra:** task size, min/max tasks, Redis size/mode, DDB mode
- **Scenarios executed** + parameters
- **Results tables:** TTFT p50/p95/p99; completion ratio; 4xx/5xx; scaling timeline
- **Identified bottlenecks** + fixes applied
- **New recommended production settings:**
  - MAX_CONCURRENT_STREAMS_PER_TASK
  - Autoscaling thresholds
  - Min tasks
  - Redis sizing

---

## 13. Definition of Done (M11 acceptance checklist)

- [ ] Load harness exists (scripts + docs) and can be run repeatably
- [ ] SSE streaming is properly tested (TTFT + completion ratio measured)
- [ ] Staging capacity is measured up to at least target concurrency (e.g. 2,000 streams) OR a justified limit is documented
- [ ] Capacity curves and a written Capacity Report are produced
- [ ] At least 3 bottlenecks are identified and addressed (or explicitly accepted with mitigation)
- [ ] Autoscaling is validated (scale-out/in behaviors documented and tuned)
- [ ] Performance regression gate exists (nightly or release-time) with thresholds tied to M0 SLOs
