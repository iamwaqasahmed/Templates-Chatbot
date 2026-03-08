# M8 — Redis Layer v1 (Rate Limiting, Quotas, Concurrency Control, Ephemeral State) — Technical Design v1

M8 adds a global, low-latency control plane to protect and stabilize your chat platform under real-world load: bursts, abusive clients, retry storms, and “one tenant melting the cluster.” Redis is not the source of truth (DynamoDB is, from M7). Redis is used for fast, ephemeral enforcement and coordination.

This milestone is the difference between “it works in a demo” and “it survives the internet.”

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- **Enforce rate limits and burst controls** at multiple levels: per IP (supplement WAF), per user, per tenant, per endpoint class (stream vs non-stream).
- **Enforce concurrency limits** (active streams per user/tenant).
- **Enforce quota limits** (e.g. tokens/day per tenant) with fast checks.
- **Provide distributed locking** primitives to prevent multi-instance race conditions: conversation “single writer” (optional), idempotency “in-progress guard” (complements DynamoDB).
- **Optional hot caches** for expensive reads: conversation metadata, tenant config / feature flags / plan tier.
- **Do it securely:** private subnets, TLS, auth token, encryption at rest, least exposure.
- **Full Terraform module** + env stacks + alarms.

### Non-Goals (later)

- Long-term “memory store” (Redis shouldn’t hold durable conversation history)
- Streaming resume buffers (optional extension; v1 can skip or keep minimal)
- Global multi-region Redis (M17+)

### Outcomes

- ElastiCache Redis deployed (Multi-AZ) in private-data subnets
- FastAPI middleware enforces: IP/user/tenant rate limits, concurrency gating, token/day quotas (fast pre-check + finalize)
- CloudWatch alarms for Redis health + eviction + CPU/memory
- Runbooks for throttling, false positives, outages

---

## 2. Redis Deployment Architecture (AWS ElastiCache)

### 2.1 Recommended Redis mode

**ElastiCache for Redis, Replication Group, Multi-AZ with automatic failover**

| Mode | Use case |
|------|----------|
| **A) Non-cluster** | Primary + 1–2 replicas; good up to moderate throughput (often sufficient for thousands of users if keys/ops are lightweight) |
| **B) Cluster mode** | Multiple shards, replicas per shard; best for very high write rate, many tenants, horizontal scale for Redis |

**Recommendation:** Start with cluster mode disabled in dev/staging. Use cluster mode enabled in prod if scale is large or for future-proofing. Keep client code compatible with a Redis cluster client from day 1.

### 2.2 Security posture

- **Subnet group:** private-data subnets only
- **Security group:** inbound 6379 only from sg_app_tasks and sg_workers
- **In-transit:** TLS enabled
- **At rest:** encryption enabled
- **Redis AUTH:** ElastiCache auth token stored in Secrets Manager
- No public endpoints, no internet route to data subnets

### 2.3 Parameter group (baseline)

- **maxmemory-policy:** volatile-ttl (prefer eviction of keys with TTL)
- timeout / tcp-keepalive tuned moderately
- **slowlog:** enable at a safe threshold (slowlog-log-slower-than) for debugging

### 2.4 Sizing philosophy (v1)

Redis usage: mostly INCR/Lua for rate limits, concurrency counters, small TTL caches. Typically not memory-huge but can be write-heavy.

---

## 3. What Redis Is Used For (and what it is not)

| Use Redis for (M8) | Don’t use Redis for |
|-------------------|----------------------|
| Rate limiting (atomic, fast) | Durable conversation storage (DynamoDB in M7) |
| Concurrency control (active streams per user/tenant) | Long-term analytics |
| Quota pre-check / reservation (tokens/day, requests/day) | Anything that must survive Redis flush/failover without rebuild logic |
| Distributed locks (short-lived) | |
| Ephemeral caches (tenant config, feature flags, optional JWKS) | |

---

## 4. Enforcement Model: Limits You Should Implement

### Layered defenses

**4.1 Edge layer (WAF/CloudFront)** — Rate-based per-IP; bot reputation rules

**4.2 App layer (Redis-enforced)**

| Endpoint class | Controls |
|----------------|----------|
| **A) Streaming Chat** (/v1/chat/stream) | max streams per user, max streams per tenant; requests/min per user/tenant; “inflight request” guard per conversation |
| **B) Non-stream Chat** (/v1/chat) | requests/min per user/tenant; requests/min per IP |
| **C) Reads** (GET /conversations, GET /messages) | Higher cache hit potential; rate-limit lightly |

### 4.3 Suggested initial limit defaults (example)

Parameterize by tenant plan tier later; start with sane defaults:

| Scope | Limit (example) |
|-------|------------------|
| **Per IP** | 60 req/min (API); 300 req/5 min (WAF); tune later |
| **Per user (stream)** | 10 req/min; max 2 concurrent streams |
| **Per user (non-stream)** | 20 req/min |
| **Per tenant (stream)** | 200 req/min; max 200 concurrent streams (tune by plan) |
| **Per tenant (non-stream)** | 500 req/min |

System must make it easy to adjust by config.

---

## 5. Algorithms (Deep, practical choices)

### 5.1 Rate limiting: Token Bucket (recommended)

- **Why:** Allows bursts (good UX); enforces average rate (protects system); simple and robust at scale.
- **State per key:** tokens (current), last_refill_ms.
- **Atomic update:** Use **Lua script** to compute refill + consume in one operation.

**Lua sketch (conceptual)**

- KEYS[1] = bucket key
- ARGV = now_ms, capacity, refill_per_sec, cost, ttl_sec
- Returns: allowed (0/1), tokens_left

**TTL:** Always set TTL so inactive users/tenants keys vanish.

### 5.2 Alternative: Sliding window log

- More accurate but memory heavier. Use only if you need strict per-second enforcement.

### 5.3 Fixed window counter

- INCR + EXPIRE is fine for low-value read endpoints.

**Recommendation:** Token bucket for /chat and /chat/stream; fixed window for low-value read endpoints.

---

## 6. Concurrency Control (Active Streams)

### 6.1 Why you need it

Streaming creates long-lived connections. Cap: per-user active streams; per-tenant active streams; per-task (M6) + global caps (Redis).

### 6.2 Concurrency keys

- `conc:u:{tenant_id}:{user_id}`
- `conc:t:{tenant_id}`

### 6.3 Pattern: increment on stream start, decrement on end

- **Atomicity:** Lua script: check current count; if under limit, increment; set TTL as safety.
- **On normal completion:** decrement.
- **On crash/disconnect:** TTL cleans up.
- **Safety TTL:** Slightly longer than max expected stream duration (e.g. 10–15 minutes).

### 6.4 Handling disconnects and exceptions

In FastAPI: try/finally around streaming loop; decrement counts in finally. If process dies, TTL prevents permanent leakage.

---

## 7. Quotas (Tokens/day, Requests/day)

### 7.1 Why Redis for quota checks

Reject early before invoking expensive LLM calls.

### 7.2 Two-phase quota strategy (best practice)

| Phase | Action |
|-------|--------|
| **1 — Pre-check / reservation** | Estimate cost (input token estimate, max output tokens); reserve budget in Redis. If reservation exceeds plan limit → 429/403 (quota exceeded) |
| **2 — Finalize** | After response completes, compute actual usage; adjust counter (add/correct delta: actual − reserved). Persist final usage to DynamoDB/Aurora later (M15/M18) |

**TTL:** Keys expire after 2–3 days to cover time zones and reconciliation.

### 7.3 Key design

- `quota:tok:day:{tenant}:{yyyymmdd}`
- `quota:req:day:{tenant}:{yyyymmdd}`
- Per-user keys if needed.

---

## 8. Distributed Locks (for correctness under retries)

Redis locks are not primary correctness (DynamoDB idempotency is) but add protection and reduce duplicate work.

### 8.1 Use cases

- Prevent two servers from generating assistant response concurrently for same conversation+request: `lock:chat:{tenant}:{conversation_id}` (short TTL)
- Prevent simultaneous “regen”: `lock:regen:{tenant}:{conversation_id}`

### 8.2 Lock algorithm

- **Acquire:** `SET key value NX PX <ttl_ms>`
- **Release:** Only if value matches (Lua compare-and-del)
- **TTL:** Short (e.g. 30–120s); renew if needed for long operations (optional)
- **On lock failure:** Return 409 conflict or 202 in_progress per UX design.

---

## 9. Caching (Optional but valuable)

### 9.1 Safe cache targets

| Key pattern | Content | TTL |
|------------|---------|-----|
| `cfg:tenant:{tenant_id}` | Tenant config / plan tier / feature flags | 60–300s |
| `cache:convmeta:{tenant}:{user}:{conv}` | Conversation metadata for list views | 30–120s |
| JWKS | JWKS fetch results (optional; careful with rotation) | 5–15 min |

### 9.2 Cache rules

- TTL everything
- Cache only “derived” or safe-to-stale config
- Always have a DynamoDB fallback

---

## 10. Failure Modes & Resilience

### 10.1 If Redis is down

| Philosophy | Behavior | Pros / cons |
|------------|----------|-------------|
| **Fail-closed** | Reject chat endpoints (503/429); cannot enforce quotas/limits | Protects cost and abuse; hurts availability |
| **Fail-open with safety clamps** (recommended) | Continue serving with: conservative per-task concurrency cap (M6), WAF per-IP; optionally disable stream. Log “redis_unavailable” and alarm | Balanced |

**Recommended:**

- **/chat/stream:** Fail-open but reduce capacity (e.g. lower MAX_CONCURRENT_STREAMS_PER_TASK)
- **Admin endpoints:** Fail-closed (no changes without enforcement/logging)
- **Quota enforcement:** If Redis down, conservative fallback (reject if tenant low tier or unknown)

### 10.2 If Redis is slow

- Time out Redis calls quickly (e.g. 50–150ms)
- If timeouts spike, degrade behavior and alert
- Keep scripts efficient; avoid large key scans

---

## 11. Implementation in FastAPI (Middleware + Guards)

### 11.1 Order of checks

1. JWT auth (M4)
2. Determine “endpoint class” (stream / non-stream / read / admin)
3. Rate-limit check(s) (token bucket)
4. Concurrency acquire (for stream)
5. Quota reserve (for chat calls)
6. Proceed to orchestrator
7. On completion/failure: release concurrency + finalize quota + update request status

### 11.2 Required identifiers

- tenant_id, user_id
- **Client IP:** from CloudFront/ALB headers you trust; never trust arbitrary X-Forwarded-For unless from known proxy layers

### 11.3 Redis client requirements

- Single **pooled async client** per process
- Configure: connection pool size, socket timeouts, conservative retry strategy

---

## 12. Terraform Implementation (ElastiCache + Alarms)

### 12.1 New module: `modules/redis`

Creates:

- `aws_elasticache_subnet_group` (private-data subnet IDs from M3)
- `aws_security_group` for Redis
- `aws_elasticache_replication_group`: Multi-AZ, automatic failover, encryption in transit, encryption at rest, auth token
- Parameter group (optional): eviction + slowlog settings
- **CloudWatch alarms:** CPUUtilization, DatabaseMemoryUsagePercentage, Evictions, CurrConnections, ReplicationLag (if replicas)

### 12.2 Live stack layout

```
infra/terraform/live/{dev,staging,prod}/data/
  redis.tf
  outputs.tf
```

### 12.3 Secrets Manager integration

- Store Redis auth token in Secrets Manager (manual or Terraform random_password; careful with rotation)
- ECS task definition pulls: REDIS_AUTH_TOKEN and REDIS_URL

---

## 13. Key Naming Convention (important for operability)

| Purpose | Pattern |
|---------|---------|
| **Rate limit** | `rl:ip:{ip}:{bucket}`, `rl:u:{tenant}:{user}:{bucket}`, `rl:t:{tenant}:{bucket}` — bucket: chat_stream, chat, read, admin |
| **Concurrency** | `conc:u:{tenant}:{user}:stream`, `conc:t:{tenant}:stream` |
| **Quota** | `quota:tok:day:{tenant}:{yyyymmdd}`, `quota:req:day:{tenant}:{yyyymmdd}` |
| **Locks** | `lock:chat:{tenant}:{conversation_id}`, `lock:regen:{tenant}:{conversation_id}` |
| **Caches** | `cfg:tenant:{tenant}`, `cache:convmeta:{tenant}:{user}:{conv}` |

---

## 14. Monitoring, Dashboards, and Runbooks (M8-level)

### 14.1 Metrics to alarm on (Redis)

- Evictions > 0 sustained
- Memory usage > 80–90%
- CPU > 70–80% sustained
- Connection spikes
- Replication lag (if present)

### 14.2 App metrics (counters)

- `rate_limit_denied_total{scope=bucket}`
- `quota_denied_total`
- `concurrency_denied_total{scope=user|tenant}`
- `redis_timeouts_total`
- `redis_failopen_total`

### 14.3 Runbooks

| Scenario | Actions |
|----------|---------|
| **Rate limit complaints** | Inspect scope (ip/user/tenant); check tenant plan; adjust bucket params in config store |
| **Evictions** | Increase node size or adjust TTL; ensure volatile-ttl and keys have TTL |
| **Redis outage** | Confirm fail-open; tighten WAF; reduce API task concurrency; restore Redis and clear alarms |

---

## 15. Testing Plan (must prove it works)

### Unit tests

- Token bucket script correctness
- Concurrency acquire/release behavior
- Quota reserve/finalize calculations

### Integration tests (docker-compose)

- Start Redis locally
- Validate: 429 on rate limit breach; 503/overload for concurrency cap; quota exceeded; lock preventing parallel processing

### Load tests (mini soak)

- Simulate 500–2000 concurrent streams; bursty traffic
- Verify: no Redis CPU runaway; stable latency for Redis checks (< 5–15ms typical); API remains responsive

---

## 16. Definition of Done (M8 acceptance checklist)

- [ ] ElastiCache Redis deployed in private-data subnets, Multi-AZ, TLS, auth token, encryption at rest
- [ ] FastAPI enforces: per-IP, per-user, per-tenant rate limits (token bucket for chat); concurrency caps for streaming; token/day quota reserve + finalize
- [ ] Distributed lock available for chat concurrency edge cases
- [ ] All Redis keys have TTL; eviction policy tuned for TTL keys
- [ ] Redis alarms configured and documented runbooks exist
- [ ] Fail-open/fail-closed behavior defined and implemented with metrics
- [ ] Tests cover enforcement correctness and basic performance sanity
