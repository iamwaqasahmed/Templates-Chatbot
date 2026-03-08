# M18 — Cost Optimization + Performance Engineering v1 (FinOps, Margin Control, Cost-Aware Routing, Efficiency at Scale) — Technical Design v1

M18 is where you protect margins and keep unit economics healthy as you grow. You’ll build a FinOps layer that makes cost drivers obvious (per tenant, per feature, per model), then implement targeted optimizations: caching, batching, model routing, cost-aware autoscaling, and data lifecycle controls. This milestone should reduce spend without hurting reliability (M17) or UX (SLOs from M0).

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- **Cost visibility and attribution:** per-tenant / per-plan / per-feature cost and margin.
- **Identify and reduce top cost drivers:** LLM tokens and provider calls; RAG embeddings and vector search; ECS/Fargate (SSE overhead); Redis; OpenSearch/Aurora; CloudWatch; NAT egress.
- **Cost-aware runtime strategies:** caching and deduping (prompt + retrieval); batching and concurrency; model routing / fallback; budget-based throttling / degrade modes.
- **Automated cost guardrails:** budgets, alarms, anomaly hooks; “kill switches” for high-cost features per tenant.

### Non-Goals (later)

- Advanced ML-driven routing optimization
- Active-active multi-region cost balancing
- Full internal chargeback (beyond M15/M16 reporting)

### Outcomes

- **Dashboards** show top spend by tenant and by feature.
- **Policies** automatically prevent runaway costs.
- **Concrete reductions (typical targets):** 20–50% lower LLM cost (caching + routing); 20–40% lower ingestion embedding (dedupe + chunk tuning); reduced NAT and logging via endpoints + retention + sampling.

---

## 1. Establish the FinOps Data Model (Cost Attribution)

### 1.1 Unit cost catalog (“Pricebook”)

**Table: cost_pricebook** (versioned)

- provider (openai/bedrock/anthropic etc.)
- model, effective_from
- cost_per_1k_input_tokens, cost_per_1k_output_tokens
- embedding costs, reranker costs
- vector store cost coefficients (optional), compute cost coefficients (optional)

**v1:** Manual updates (or admin UI sync later).

### 1.2 Costed usage events

**Extend UsageEvent (M15)** with:

- **cost_estimate_usd**
- **cost_breakdown:** llm_usd, embeddings_usd, vector_search_usd (approx), compute_usd (approx), logs_usd (optional)
- **margin_estimate_usd** = revenue estimate − cost estimate (for paid plans)

Approximate compute attribution with per-request coefficients; improve over time.

---

## 2. FinOps Dashboards (What you need daily)

### 2.1 Tenant-level unit economics

- Top 20 tenants by LLM cost (daily, weekly)
- Cost per 1,000 messages (by tenant)
- Cost per active user (DAU/WAU if tracked)
- Cost per plan tier vs revenue (margin estimate)

### 2.2 Feature cost drivers

- RAG ingestion embedding spend (daily)
- RAG retrieve calls and latency vs cost
- Tool calls that invoke LLM (rerankers, query rewriting)
- Async job runtime (heavy jobs)

### 2.3 Infrastructure cost proxies

- ECS task hours (api + worker)
- ALB LCUs
- NAT data processed (hidden cost)
- OpenSearch storage &amp; compute
- CloudWatch log ingestion volume

**v1:** Use CloudWatch + usage events + approximate coefficients; Cost Explorer/CUR later for true infra-by-tenant.

---

## 3. Big Ticket Optimizations (Prioritized)

### Cost driver #1: LLM calls (usually 70–95% of variable cost)

#### 3.1 Prompt + response caching (high impact)

- **Exact cache** (Redis or DynamoDB): Key = hash of normalized system prompt version, normalized user input, tool context fingerprint, model + params. Value = response + usage + TTL.
- **Semantic cache** (optional v1+): Embed query; look up nearest cached prompts (FAQ-like). **Rules:** Only for tenants that allow it; never cache “sensitive” or no-cache data class. TTL: 10 min–24h. **Expected savings:** 10–40%.

#### 3.2 Token hygiene (always worth it)

- Trim history: summarize older messages (M12 job), keep last N turns, remove redundant tool outputs, compress system prompts, cap output tokens per plan. **Expected savings:** 10–30%.

#### 3.3 Model routing policy (massive lever)

- **Default** cheap model for most users; **upgrade** to expensive model when: complexity score, high-value tenant, long context, tool-heavy flows.
- **v1 rules:** model_small for short questions, no tools, low plan; model_large for tool planning, long context + RAG, enterprise. **Fallback:** provider errors → alternate model/provider (M17). **Expected savings:** 20–60%.

#### 3.4 Streaming efficiency

- Enforce concurrency caps (M8); shorten max stream duration; send tokens in larger chunks (e.g. buffer 50–100ms); fewer app processes per task; tune memory.

### Cost driver #2: RAG (embeddings + vector store)

#### 3.5 Chunk tuning and dedupe

- Lower chunk overlap; dedupe identical chunks across versions; cap max chunks per doc; compress extracted text storage. **Expected savings:** 20–50% on embedding.

#### 3.6 Retrieval optimization

- Reduce top_k (often 5 enough); multi-query only for complex queries; reranker for enterprise only; **cache retrieval** by (tenant, query_hash, filters) TTL 5–30 min. **Expected savings:** 10–30%.

#### 3.7 Vector store lifecycle

- Delete vectors for deleted docs immediately; expire old versions; ILM/retention for OpenSearch if applicable.

### Cost driver #3: AWS infra hidden costs

#### 3.8 NAT egress reduction

- Add VPC endpoints (SQS, Secrets Manager, ECR, CloudWatch); route AWS traffic through endpoints; only LLM provider via NAT. **Bedrock** keeps traffic internal → big NAT reduction.

#### 3.9 CloudWatch logs cost control

- Sample info logs (keep errors 100%); reduce verbosity in prod; shorten retention; Firehose → S3 for long retention; avoid high-cardinality metrics.

#### 3.10 ECS/Fargate sizing + Spot

- Right-size tasks (M11 data). **Fargate Spot** for workers (not API). API on-demand; workers on Spot with retry-safe jobs (M12).

---

## 4. Cost Guardrails (Prevent Runaway Spend)

### 4.1 Per-tenant budgets

- **Config:** max_cost_estimate_usd_per_day, max_tokens_per_day, max_rag_embed_tokens_per_day.
- **When breached:** “budget exceeded” mode: block high-cost features, reduce model tier, require admin approval.

### 4.2 Platform budgets

- **AWS Budgets:** monthly spend thresholds; alerts to ops channels (integrate with incident flow).

### 4.3 Anomaly detection hooks (v1)

- Detect spikes: tokens per tenant per minute; tool call rates; RAG ingestion volume. **Actions:** auto-throttle tenant; create incident ticket.

---

## 5. Performance Engineering (Keep SLO while reducing cost)

### 5.1 Platform overhead vs provider latency

- M10 traces already separate them. **Enforce:** platform overhead p95 stays below threshold; optimizations must not degrade TTFT beyond agreed bounds.

### 5.2 Cache correctness and invalidation

- Include **prompt version** and **tool registry version** in cache key; **rag index version** in retrieval cache key (doc update busts cache). Store cache hit/miss metrics.

### 5.3 Batching and pooling

- **Embeddings:** batch to max batch size. **OpenSearch:** don’t over-batch (latency). **Provider:** connection pooling and HTTP keep-alive.

---

## 6. Implementation Plan (Concrete Deliverables)

### 6.1 New subsystems

| Subsystem | Role |
|-----------|------|
| **Cost Estimator** | Maps usage → cost via pricebook; used at event emission (M15) |
| **Cache Layer** | Exact LLM cache (Redis); retrieval cache (Redis) |
| **Model Router** | Rules: plan, context size, tool usage, cost budget state, provider health (M17) |
| **Budget Enforcer** | Daily cost/token checks; sets tenant state; Redis fast path + authoritative aggregates |

### 6.2 Data additions

- **cost_pricebook** table
- **tenant_budget_state** table: ACTIVE | WARN | LIMITED | SUSPENDED; reasons and timestamps

### 6.3 Jobs (M12)

- cost_rollup_daily
- budget_enforce_daily
- optional cache_warm jobs

---

## 7. Observability for Cost Controls

### Metrics

- llm_cache_hit_rate, rag_retrieval_cache_hit_rate
- avg_tokens_in/out_by_plan, cost_estimate_usd_total_by_plan
- budget_state_changes_total
- model_routing_decisions_total{model}, fallback_invocations_total{provider}

### Dashboards

- “Cost Overview”, “Cache Efficiency”, “Routing Mix”, “Top Tenants by Cost”, “RAG Spend”

### Alarms

- Cache hit rate suddenly drops (possible bug)
- Routing shifts unexpectedly to expensive models
- Cost anomaly spike per tenant

---

## 8. Testing &amp; Validation (Don’t guess, measure)

### 8.1 A/B testing (optional but ideal)

- Route small % to “optimized routing.” Compare: cost per request, TTFT p95, satisfaction signals, error rates.

### 8.2 Regression gates (extend M11)

- “Cost per 1k messages” must not increase &gt; X%; TTFT p95 must not degrade &gt; Y%; cache correctness tests pass.

### 8.3 Load test with caching enabled

- Repeat M11 scenario A; compare task counts needed for same concurrency.

---

## 9. Terraform/Infra Changes

- **VPC endpoints** to reduce NAT: SQS, Secrets Manager, CloudWatch Logs, ECR API/DKR
- **Firehose → S3** for log archival (optional)
- **Managed Grafana** (optional)
- **AWS Budgets** resources (IaC-managed budgets/alerts, optional)

---

## 10. Definition of Done (M18 acceptance checklist)

- [ ] Pricebook exists and cost estimates computed for all major usage events (chat/tool/job/rag)
- [ ] FinOps dashboards show cost by tenant/plan/feature and top drivers
- [ ] Exact LLM cache implemented with safe keys, tenant controls, and hit-rate metrics
- [ ] Retrieval cache implemented (rag_retrieve) with correct invalidation
- [ ] Model routing policy implemented with plan-aware and budget-aware decisions
- [ ] Budget guardrails exist (per-tenant daily caps) with degrade-mode behavior
- [ ] NAT and logging cost controls applied (endpoints, retention, sampling)
- [ ] Load tests demonstrate lower cost or lower required task count at same SLO
- [ ] Alarms exist for cost anomalies and unexpected routing/caching regressions
