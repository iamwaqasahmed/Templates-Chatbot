# M17 — Reliability & DR v1 (Multi-AZ Hardening, Cross-Region Recovery, Backups, Chaos/Drills, Incident Response) — Technical Design v1

M17 is where your platform becomes enterprise-grade reliable. You’ll harden for predictable operations: AZ failures, dependency outages, deployment mistakes, data corruption, and provider instability—with measured RTO/RPO targets, tested recovery procedures, and automated rollback.

This milestone assumes: ECS/Fargate + ALB (M9), Observability (M10), Load tests (M11), Jobs (M12), Tools (M13), RAG (M14), Metering/Billing (M15), Payments (M16).

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- **In-region HA (Multi-AZ)** for all runtime components with no single-AZ dependency.
- **Cross-region DR** with a defined pattern (Pilot Light or Warm Standby) and tested failover.
- **Backup & restore** for all stateful components (DynamoDB, S3, OpenSearch/Aurora, Redis config, Secrets).
- **Deployment safety:** progressive delivery + automated rollback.
- **Dependency resilience:** LLM provider, Redis, OpenSearch—degrade safely.
- **Operational maturity:** incident response, runbooks, game days, postmortems.

### Non-Goals (later)

- Active-active multi-region (global traffic + global data consistency)—DR v2
- Full compliance certification (SOC2/ISO)—align with it

### Outcomes

- Documented and tested **RTO/RPO**, with quarterly DR drills.
- **Terraform-managed DR** infrastructure in a secondary region.
- **Automated backups** + restore playbooks.
- **Canary/blue-green** releases with alarm-driven rollback.
- **Chaos test suite** + runbooks + on-call readiness.

---

## 1. Reliability Targets (SLO + DR objectives)

### In-region SLO (example)

| Metric | Target |
|--------|--------|
| API Availability | 99.9% monthly (excluding planned maintenance) |
| Streaming Stability | ≥ 99.5% completion (excluding client disconnects) |
| p95 TTFT | &lt; 2.5s (measure platform overhead separately) |

### DR targets (example)

| Metric | Target |
|--------|--------|
| **RTO** (time to restore in DR) | 30–60 minutes |
| **RPO** (max data loss) | Conversations/messages: ≤ 5 min (best effort). Billing events: ≤ 1 min if strict. |

These drive which DR pattern you pick.

---

## 2. In-Region High Availability Hardening (Multi-AZ)

### 2.1 Compute (ECS/Fargate)

- ECS services across **2–3 AZs** (private-app subnets per AZ).
- **min tasks ≥ 3** in prod (one per AZ ideal).
- **Graceful draining** solid (M9): long-lived SSE; conservative scale-in cooldown.

### 2.2 Load balancer

- ALB across multiple AZs (standard).
- Health checks use /ready; optional dependency checks (Redis)—don’t fail healthy tasks for temporary Redis slowness unless intended.

### 2.3 Networking

- **NAT Gateways per AZ** (avoid single NAT) if NAT needed.
- **VPC endpoints** preferred: DynamoDB, S3, SQS, Secrets Manager, ECR, CloudWatch Logs. Route tables correct per subnet/AZ.

### 2.4 Redis (ElastiCache)

- Multi-AZ with automatic failover (M8). Confirm replication group spans AZs; alarms on failover, memory, evictions. App tolerates brief reconnects and fail-open (M8).

### 2.5 DynamoDB

- On-demand + **PITR** enabled. Avoid hot partitions (M11). Standardized backoff + retry (SDK + jitter).

### 2.6 OpenSearch / Aurora (if used for RAG)

- **OpenSearch:** multi-AZ + snapshotting. **Aurora:** Multi-AZ cluster, automated backups, reader endpoint if heavy reads.

---

## 3. Cross-Region DR Pattern (Choose one for v1)

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A — Pilot Light** (recommended v1) | VPC, ALB, ECS defined; services scaled to 0 or 1; data replication where feasible. On incident: scale up + DNS switch. | Cheaper, simpler | RTO ~30–60m |
| **B — Warm Standby** | DR runs at low capacity (min tasks 1–2, vector store on). Scale up + DNS on incident. | Lower RTO | Higher cost |

**Recommendation:** Pilot Light for most; Warm Standby if customers need faster RTO.

---

## 4. Data DR & Backups (Per Data Store)

### 4.1 DynamoDB (Conversations, Messages, Requests, Jobs, Billing events)

- **Backups:** PITR on all critical tables (primary); optional on-demand monthly snapshots.
- **Cross-region:** (A) Restore from PITR into DR (simpler, moderate RPO); (B) **Global Tables** for low RPO (usage_events, stripe_webhook_events; optionally conversations/messages).
- **Recommendation:** Global Tables for billing/stripe if strict RPO; conversations/messages PITR restore in v1 or Global Tables if near-zero loss needed.

### 4.2 S3 (Uploads, RAG artifacts)

- **Enable:** Versioning, SSE-KMS, lifecycle policies.
- **DR:** **CRR** for critical buckets (rag-uploads, rag-artifacts, billing exports). KMS key policies allow replication.

### 4.3 OpenSearch (Vector store)

- Snapshots to S3 (automated). **Cross-region:** CRR snapshot bucket or copy to DR bucket. **Recovery:** restore snapshot into DR domain; restore time often dominates RTO.

### 4.4 Redis

- Not durable source of truth. **DR:** Recreate in DR; warm caches optional. App degrades gracefully. Do not rely on Redis replication for DR correctness.

### 4.5 Secrets Manager / KMS

- **Secrets:** Replicate to DR (manual/automated). **KMS:** Per-region CMKs; policies match.

### 4.6 Terraform state / CI artifacts

- **State:** S3 versioning + MFA delete (if feasible); optional CRR to DR; lock table backed up. **ECR:** Rebuild in DR CI (preferred) or replicate images.

---

## 5. Traffic Failover Design (DNS + Edge)

### 5.1 Route53 failover (v1)

- **api.example.com:** primary ALB (region A), secondary ALB (region B). **Health checks:** Route53 hitting /ready per region (via CloudFront or direct). **Failover policy:** primary if healthy, else secondary.

### 5.2 CloudFront strategy

- Two origins (primary ALB, secondary ALB); **origin failover** configured. Keep Route53 failover as well. **Define** which layer is authoritative (CloudFront vs Route53) to avoid confusion.

---

## 6. Deployment Safety: Progressive Delivery + Auto Rollback

### 6.1 Blue/Green for ECS (recommended)

- **CodeDeploy** for ECS blue/green: two target groups (blue, green); shift traffic gradually; **rollback if alarms fire**.

### 6.2 Canary release (alternative)

- Weighted routing (CloudFront or ALB): 1% → 10% → 50% → 100% with automated checks.

### 6.3 Automated rollback triggers (from M10)

- 5xx rate spike; latency p95 spike; stream error ratio; Redis timeouts; job failure ratio.

### 6.4 Deployment guardrails

- Freeze deploys during incidents. **Pre-flight:** capacity headroom; no ongoing throttles; no DLQ backlog.

---

## 7. Dependency Resilience (LLM provider & internal deps)

### 7.1 Provider failover policy

- If provider 429/5xx above threshold: **circuit breaker** (e.g. 60s); then **fail fast** with clean error **or** route to fallback model/provider if configured.

### 7.2 Degraded modes

- **Predefine:** disable RAG ingestion; reduce max tool steps / max output tokens; disable streaming for free tier if needed; tighten rate limits. **Control** via config store (tenant/platform config cached in Redis).

---

## 8. Backup & Restore Playbooks (Executable)

### 8.1 DynamoDB restore

- Choose restore point → restore tables into DR → re-point config (Terraform/SSM) → validate read/write and billing integrity.

### 8.2 OpenSearch restore

- Provision DR domain (Pilot Light: minimal); restore snapshot from S3 → validate retrieval and mappings.

### 8.3 S3 restore

- Ensure CRR healthy → validate latest objects in DR bucket and KMS decrypt.

### 8.4 Full failover runbook

1. Declare incident + freeze deploys.
2. Decide failover criteria (SLO breach, region outage).
3. **Bring up DR compute:** scale ECS; enable worker.
4. **Restore/confirm data:** DynamoDB restore or Global Tables; OpenSearch restored.
5. **Switch traffic:** Route53 / CloudFront failover.
6. **Validate:** auth, chat, jobs, billing portal + webhooks.
7. **Communicate** status + timeline.
8. **Post-incident:** reconcile usage events and Stripe webhooks; emit adjustments (M15) if needed.

---

## 9. DR Testing (“Game Days”) + Chaos Engineering

### 9.1 DR drills (quarterly minimum)

- Simulate region outage in staging then prod-like. Measure RTO/RPO. Record results and update runbooks.

### 9.2 Chaos experiments (controlled, staging)

| Area | Experiment | Success criteria |
|------|------------|------------------|
| **Compute** | Kill 30% of api tasks during load; force rollback via 5xx | No outage; rollback works |
| **Redis** | Latency spike; Redis down | Fail-open and rate limiting behave |
| **DynamoDB** | Simulate throttling | Backoff and clean overload errors |
| **SQS** | Stop workers, build backlog; poison messages | Autoscaling catches up; DLQ alerts |
| **OpenSearch** | Deny access | RAG fails gracefully, no meltdown |

Each experiment: **hypothesis**, **blast radius**, **abort conditions**, **success criteria**, **postmortem notes**.

---

## 10. Incident Response Program

### 10.1 Incident roles (minimum)

- Incident Commander (IC), Communications lead, Ops lead (infra), App lead (backend), Scribe.

### 10.2 Comms templates

- Internal status every 15–30 min; customer status page; post-incident summary.

### 10.3 Postmortems

- Blameless; timeline + contributing factors; corrective actions with owners; link to metrics/traces.

### 10.4 On-call readiness

- Paging route (SNS → PagerDuty/Slack/email); severity definitions; escalation policy; “stop the bleeding” runbooks first.

---

## 11. Terraform Structure for DR

### 11.1 Multi-region stacks

- **primary_region** and **dr_region**; separate state per region.
- **Example:** infra/terraform/live/prod/primary/..., prod/dr/..., prod/global/ (Route53, CloudFront, shared configs).

### 11.2 DR modules

| Module | Contents |
|--------|----------|
| **modules/dr_network** | VPC/subnets/SG mirrored |
| **modules/dr_compute** | ECS cluster, ALB, minimal services |
| **modules/dr_data_restore** | Placeholders + IAM + snapshot buckets |
| **modules/dr_dns_failover** | Route53 health checks + failover records |

### 11.3 Config & switches

- **SSM** or **platform_config** table: active_region = primary|dr. Apps use only if needed (prefer DNS for traffic).

---

## 12. Billing & Payments DR (Special care)

### 12.1 Webhook processing

- Only **one region** should process Stripe events at a time. **Strategy:** Webhook receiver stores event and enqueues job; worker checks **active_region** flag before processing. Alternative: route webhooks only to primary via DNS (riskier during partial outages).

### 12.2 Usage reporting

- Same gate: only active region sends usage to Stripe. Checkpoint table (M16) prevents double reporting.

### 12.3 Reconciliation after failback

- Reconcile stripe_webhook_events (Global Tables recommended); run usage_reconcile job (M15).

---

## 13. Definition of Done (M17 acceptance checklist)

- [ ] All runtime services are Multi-AZ with no single-AZ dependency (ALB, ECS, NAT/endpoints, Redis, data paths)
- [ ] DR region infrastructure exists (Pilot Light or Warm Standby) via Terraform, regularly applied
- [ ] Backups enabled and tested: DynamoDB PITR + restore; S3 versioning + CRR; OpenSearch/Aurora snapshot + restore
- [ ] DNS/edge failover implemented and validated in staging
- [ ] Progressive delivery with automated rollback on alarms
- [ ] Degraded-mode switches for provider and internal dependency failures
- [ ] DR drill executed end-to-end with measured RTO/RPO and documented outcomes
- [ ] Chaos tests executed in staging with documented findings and fixes
- [ ] Incident response program: roles, runbooks, comms templates, postmortem process
- [ ] Billing/webhook processing gated to prevent double-processing during DR/failback
