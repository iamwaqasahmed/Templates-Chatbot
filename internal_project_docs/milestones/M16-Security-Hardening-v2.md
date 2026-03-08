# M16 — Subscriptions & Payments v1 (Stripe Billing, Checkout/Portal, Webhooks, Entitlements, Usage-to-Invoice) — Technical Design v1

M16 connects your metering (M15) to real monetization: customers can subscribe, upgrade/downgrade, manage billing, and you can reliably keep internal “entitlements” (what a tenant is allowed to do) in sync with Stripe. This milestone is designed to be billing-grade: correct under retries, async workflows, streaming, tool calls, and eventual consistency.

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- **Stripe integration** for recurring subscriptions (fixed + usage-based).
- **Customer UX:** Start subscription via Stripe Checkout; manage via Stripe Customer Portal (or minimal custom pages).
- **Reliable webhook ingestion:** verified signatures, idempotent processing, async handling.
- **Entitlements + plan state:** internal authoritative view of what tenant can do; cached in Redis for fast enforcement (M8).
- **Usage-based billing:** periodically report usage to Stripe from M15 aggregates.
- **Operational readiness:** dashboards + alarms for billing failures and webhook delays; replay/reconciliation tools.

### Non-Goals (later)

- Complex proration/credits/refunds automation
- Multi-provider payments (PayPal, Paddle)—design for abstraction
- Full tax/VAT compliance workflows (Stripe Tax can be added later)

### Outcomes

- Tenants can **subscribe** and plan limits are enforced automatically.
- **Stripe events** update your system within seconds/minutes, safely.
- **Monthly invoice-ready totals** exist and Stripe can invoice for usage.

---

## 2. Stripe Model You’ll Use (Canonical Mapping)

### Stripe objects (what matters)

| Stripe object | Role |
|---------------|------|
| **Customer** | Represents your tenant in Stripe |
| **Checkout Session** | Hosted signup/upgrade (subscription mode) |
| **Subscription** | Plan lifecycle and billing status |
| **Invoice / PaymentIntent** | Payment outcomes and dunning |
| **Usage** | Meters + meter events (recommended) or legacy usage records |

### Internal canonical entities

- **Tenant** — your tenant
- **Plan** — your product definition
- **Entitlements** — effective permissions + quotas
- **BillingCustomer** — tenant ↔ Stripe customer mapping
- **BillingSubscription** — tenant ↔ Stripe subscription mapping
- **BillingWebhookEvent** — Stripe event ingestion and idempotency

---

## 3. Plan & Pricing Design (Best-of-best but practical)

### 3.1 Separate “Plan” from “Price”

**Internally:** plan_id (free, pro, team, enterprise); entitlements per plan (max streams, tokens/day, RAG caps, tools, SLA).

**In Stripe:** Products (“Pro”, “Team”); Prices: fixed recurring base, optional seat-based, optional usage-based (metered tokens or “AI units”).

### 3.2 Usage-based approach (recommendation)

- **v1:** Base monthly fee + usage overages. **Usage unit:** “AI tokens” or “AI units” (e.g. 1 unit = 1k tokens).
- **Reporting:** Legacy usage records (quantity + timestamp) or **new meters** (meter events; Stripe processes async). **Best practice:** M15 event store is source of truth; Stripe gets periodic summarized usage for invoicing.

---

## 4. Architecture: Services, Paths, and Trust Boundaries

### 4.1 Components

| Component | Role |
|-----------|------|
| **chat-api** (ECS) | Billing endpoints + webhook receiver |
| **Billing worker jobs** (M12) | Process webhook events and usage reporting |
| **DynamoDB billing tables** | New in M16 |
| **Stripe** | Checkout + Customer Portal + Billing |

### 4.2 Why async webhook processing

- Webhooks must **respond fast**. Pattern: verify signature → store event idempotently → enqueue **process_stripe_event** job (M12) → return 200. Stripe emphasizes webhooks for subscription lifecycle and payment failures.

---

## 5. Webhooks: Security, Idempotency, and Processing

### 5.1 Signature verification (mandatory)

- Verify **Stripe-Signature** using Stripe’s **constructEvent()** with the **raw request body**. Non-negotiable.

### 5.2 Webhook endpoint design

- **Endpoint:** POST /v1/billing/stripe/webhook (public via CloudFront→ALB).
- **Constraints:** POST only; minimal middleware (no auth); **raw body preserved** (FastAPI config).

### 5.3 Idempotency: event store

**Table: stripe_webhook_events**

| Item | Design |
|------|--------|
| **PK** | `EVENT#{stripe_event_id}` |
| **Attributes** | received_at, type, livemode, payload_s3_ref (optional) or minimal payload, processed_status (RECEIVED\|PROCESSING\|DONE\|FAILED), attempts |
| **Write rule** | PutItem with condition **attribute_not_exists(PK)** so duplicates are ignored |

### 5.4 Event types to handle (v1 minimum)

- **Subscriptions:** customer.subscription.created, customer.subscription.updated, customer.subscription.deleted
- **Invoices:** invoice.paid (subscription active), invoice.payment_failed, invoice.finalized (optional)
- **PaymentIntent** (optional): payment_intent.succeeded, payment_intent.payment_failed

Subscribe only to what you need.

### 5.5 Processing workflow (job)

**Job: process_stripe_event(event_id)**

1. Mark event PROCESSING (conditional update)
2. Fetch event details (stored payload or Stripe API)
3. Update internal state (customer/subscription/entitlements)
4. Mark DONE (or FAILED + retry via M12)

---

## 6. Billing Data Model (DynamoDB)

### 6.1 billing_customers

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}` |
| **SK** | CUSTOMER |
| **Fields** | stripe_customer_id, email, created_at, status |
| **GSI** | GSI1PK = `STRIPE_CUSTOMER#{stripe_customer_id}`, GSI1SK = `TENANT#{tenant_id}` (reverse lookup) |

### 6.2 billing_subscriptions

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}` |
| **SK** | `SUB#{stripe_subscription_id}` |
| **Fields** | stripe_subscription_id, status (trialing\|active\|past_due\|canceled\|incomplete…), current_period_start/end, price_ids and quantities, usage_item_id (if metered), cancel_at_period_end, updated_at |
| **GSI** | GSI1PK = `STRIPE_SUB#{stripe_subscription_id}` → tenant lookup |

### 6.3 tenant_entitlements (authoritative access)

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}` |
| **SK** | ENTITLEMENTS |
| **Fields** | plan_id, effective_status (ACTIVE\|GRACE\|SUSPENDED), quotas and feature flags (effective now), source (stripe\|admin\|trial), updated_at |

**Cache in Redis (M8)** for fast checks.

---

## 7. Customer Flows (End-to-end)

### 7.1 Subscribe / Upgrade (Checkout)

- **Backend:** POST /v1/billing/checkout-session (input: plan_id, seat_qty optional) → **checkout_session_url**.
- **Implementation:** Create or fetch Stripe customer for tenant; create Stripe Checkout Session (subscription mode) with Price IDs; success_url returns to app with session id. **After payment:** webhooks update entitlements.

### 7.2 Manage subscription (Customer Portal)

- “Manage billing” button → create Stripe Customer Portal session (server-side) → redirect to Stripe hosted portal.

### 7.3 Payment failures / dunning

| Event | Action |
|-------|--------|
| **invoice.payment_failed** | Move tenant to **GRACE:** reduce concurrency, disable heavy RAG, allow reading history |
| **Past due after N days** | **SUSPENDED:** block new chat; allow billing portal access |

Webhooks are the source of truth for these transitions.

---

## 8. Usage Reporting to Stripe (Connect M15 → Stripe)

### 8.1 Reporting cadence

- **Hourly** (fresher) or **daily** (simpler). Stripe allows you to choose. Meter events are processed asynchronously.

### 8.2 “Usage reporter” job

**Job: report_usage_to_stripe(tenant_id, period_start, period_end)**

1. Load tenant’s active subscription and metered item/meter config
2. Read usage from M15 aggregates (daily/hourly)
3. Convert to billable unit quantity (e.g. tokens → AI units)
4. Send to Stripe (usage record or meter event)
5. Write **checkpoint** to prevent double reporting

### 8.3 Idempotency and checkpoints (don’t double bill)

**Table: stripe_usage_checkpoints**

- PK = `TENANT#{tenant_id}`, SK = `PERIOD#{yyyyMMddHH}` (or day)
- Fields: reported_quantity, stripe_reference (usage record id or meter event id)
- **Conditional write** prevents re-reporting

### 8.4 Handling late adjustments

- If M15 emits an adjustment later: reporter can send a corrective delta in the next period (or adjustment usage record). Keep internal invoice view authoritative; Stripe is invoicing surface.

---

## 9. API Surface for Your App (Next.js + Backend)

### Tenant endpoints

- **GET /v1/billing/status** → plan, status, next renewal, limits
- **POST /v1/billing/checkout-session** → subscribe/upgrade
- **POST /v1/billing/portal-session** → manage billing
- **GET /v1/billing/invoices** (optional: Stripe or your aggregates)

### Admin endpoints

- **POST /v1/admin/billing/tenant/{id}/override-entitlements** (audited)
- **POST /v1/admin/billing/replay-webhook/{event_id}** (enqueue job)

---

## 10. Terraform / Infra Changes (AWS)

- **Secrets Manager:** STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
- **ECS task roles:** allow retrieving those secrets
- **WAF** on webhook path: rate-limit (still verify signature)
- **Optional:** EventBridge Scheduler for usage reporting jobs (daily/hourly)

---

## 11. Observability & Alerting (M10 extensions)

### Metrics

- stripe_webhooks_received_total{type}, stripe_webhooks_processed_total{status}
- stripe_webhook_processing_lag_seconds
- billing_entitlements_changes_total{reason}
- stripe_usage_reports_total{status}, stripe_usage_reported_units_total

### Alarms

- Webhook lag &gt; 5–10 minutes
- Processing failures &gt; threshold
- Spike in invoice.payment_failed
- Usage reporting failures sustained

---

## 12. Testing Strategy (must be strong)

- **Stripe test mode + Stripe CLI** to trigger events and validate signature verification.
- **Test clocks** (fast-forward billing cycles) optional but valuable.
- **Integration tests:** subscribe → webhook → entitlements ACTIVE; payment failed → GRACE → portal recovery → ACTIVE; cancel → canceled_at_period_end.
- **Billing correctness:** usage reporting checkpoint prevents duplicates; adjustments handled without double billing.

---

## 13. Definition of Done (M16 acceptance checklist)

- [ ] Stripe Checkout creates subscriptions successfully (subscription mode)
- [ ] Customer Portal session flow works for manage/cancel/update
- [ ] Webhook endpoint verifies signatures using raw body + Stripe-Signature
- [ ] Webhook ingestion is idempotent and async-processed via M12
- [ ] Internal entitlements table accurately reflects Stripe subscription state changes
- [ ] Payment failure states mapped to GRACE/SUSPENDED and enforced in API
- [ ] Usage reporting job exists and is checkpointed (legacy usage records or meters)
- [ ] Observability + alarms for webhooks, payment failures, usage reporting
- [ ] Replay/reconciliation tools exist for webhook and usage reporting failures
