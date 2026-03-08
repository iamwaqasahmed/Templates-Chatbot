# M5 — Edge + Frontend Delivery Baseline (Route53 + ACM + CloudFront + WAF + Secure Origins) — Technical Design v1

M5 creates the internet-facing layer that all users hit. It must be fast, secure, resilient, and operationally clean. This milestone delivers: custom domains + TLS, CloudFront CDN, WAF protections, secure S3 origin for the frontend, and a routing pattern for API traffic (either now or ready for M9).

---

## 1. Objectives & Outcomes

### Objectives

- Serve the **web app globally via CDN** with strong security headers.
- **Block/limit malicious traffic** before it reaches compute.
- Establish **stable DNS + certificates**.
- **Standardize routing patterns** that won’t break later (SSE streaming, admin paths, etc.).
- Produce **Terraform modules + live stacks** consistent with M2.

### Outcomes (end of M5)

- **Domain(s)** set up in Route53.
- **ACM certificates** issued correctly: CloudFront cert in **us-east-1**; regional cert(s) in deployment region for ALB (later).
- **CloudFront distribution** configured with: frontend origin S3 + Origin Access Control (OAC); optional API origin ALB (later) on `/api/*` behavior; secure response headers policy (HSTS/CSP/etc.).
- **AWS WAF WebACL** attached to CloudFront: managed rules + rate limiting + bot protections (baseline).
- **Logging pipeline:** CloudFront access logs → S3; WAF logs → S3 (via Firehose) or CloudWatch (baseline choice).
- **“Maintenance / fallback”** pattern defined (optional but recommended).

---

## 2. Domain & Routing Strategy (choose a stable pattern)

### Recommended pattern (clean separation)

| Subdomain | Target | Use |
|-----------|--------|-----|
| **app.example.com** | CloudFront (web) | Frontend |
| **api.example.com** | CloudFront or ALB (API) | API |

**Pros:** Simpler caching rules, fewer edge-cases with headers, easy CORS.  
**Cons:** One more DNS name.

### Alternative pattern (single domain, path routing)

- `app.example.com/*` → web  
- `app.example.com/api/*` → API  

**Pros:** Simplest for cookies and same-origin.  
**Cons:** Requires careful CloudFront behaviors, SSE settings, caching controls.

**Recommendation:** Use **two subdomains (app + api)**. It scales better and reduces surprises.

---

## 3. Frontend Hosting Model

| Option | Description | Best for |
|--------|-------------|----------|
| **A (recommended)** | Static frontend on **S3 + CloudFront**. Next.js static output where possible; CloudFront caches aggressively; API calls go to api.example.com. | Performance + simplicity + cost |
| **B** | **SSR frontend on ECS behind ALB + CloudFront**. CloudFront still fronting, origin is ALB. | Heavy SSR needs (auth/session, dynamic rendering) |

M5 delivers **Option A** fully. Option B remains compatible if SSR is required later.

---

## 4. CloudFront Architecture (reference)

### Web distribution

- **Origin:** S3 website bucket (private) via **OAC**
- **Behaviors:** `/*` → S3 (cached); response headers policy enforced; WAF attached

### API distribution (preferred)

- **Origin:** ALB (later M9)
- **Behaviors:** `/*` → ALB (no caching); WAF attached (API-tuned rules)

**Single-distribution alternative:** Define behavior `/api/*` → ALB and default `/*` → S3.

---

## 5. CloudFront Settings (performance + security)

### 5.1 TLS & protocol

- **Viewer protocol policy:** Redirect HTTP → HTTPS
- **Minimum TLS:** TLSv1.2_2021
- **HTTP versions:** HTTP/2 and HTTP/3 enabled (safe default)

### 5.2 Caching policies

| Origin | Path pattern | TTL / behavior | Forward |
|--------|--------------|----------------|---------|
| **Web (S3)** | Static (/_next/static/*, *.js, *.css, images) | Long TTL (1 day–365 days depending on hashing) | Minimal headers; versioned asset filenames |
| **Web (S3)** | HTML | Low TTL or no-cache (per release strategy) | Minimal |
| **API (ALB)** | All | No caching | Authorization (or cookie), Content-Type, Accept, Origin, X-Request-Id/trace headers |

Use CloudFront **Cache Policy** + **Origin Request Policy**; rely on versioned asset filenames for static.

### 5.3 SSE streaming (important for chat)

- API should respond quickly with headers (TTFT requirements).
- **CloudFront behavior for SSE:** caching disabled; keep-alive supported; compress disabled only if it interferes (usually fine).
- Application should send **periodic SSE “ping” comments** every ~15s to keep connection healthy through intermediate layers.

---

## 6. Securing the S3 Origin (OAC, no public bucket)

### 6.1 S3 bucket rules

- **Block Public Access:** ON
- **SSE:** SSE-KMS or SSE-S3 (SSE-KMS preferred for uniformity)
- **Versioning:** Optional but recommended
- **Lifecycle:** Expire old builds if you keep multiple

### 6.2 Origin Access Control (OAC)

- Use **OAC** (modern replacement for OAI).
- **Bucket policy:** Allow only CloudFront distribution to read: `s3:GetObject` on `arn:aws:s3:::web-bucket/*` with condition on CloudFront distribution ARN.

---

## 7. WAF Baseline (CloudFront WebACL)

### 7.1 Rule groups (baseline “best practice”)

Attach AWS managed rule sets:

- **AWSManagedRulesCommonRuleSet**
- **AWSManagedRulesKnownBadInputsRuleSet**
- **AWSManagedRulesAmazonIpReputationList**
- **AWSManagedRulesSQLiRuleSet**
- (Optional) **Bot Control** (cost feature; enable in prod if needed)

### 7.2 Rate limiting strategy

| Target | Suggested limit |
|--------|-----------------|
| **Web** | Rate-based rule per IP (e.g. 2,000 requests/5 min) to block obvious floods |
| **API** | Stricter per IP (e.g. 300–600 requests/5 min); additional rules for /chat or /stream if path routing |

App-level limits (Redis) remain in later milestones; WAF stops junk before it reaches the stack.

### 7.3 Geo/IP allow/deny (optional)

- Early phases: usually “allow all”.
- If business has geographic constraints: apply **GeoMatch**.

### 7.4 Size constraints and body inspection

- Set **reasonable body size limits** on API endpoints (attachments via S3 pre-signed URLs later).
- Consider excluding large endpoints from deep inspection if it causes false positives.

### 7.5 WAF logging

Enable WAF logging to:

- **Kinesis Data Firehose → S3** (best for long retention + analysis), or
- **CloudWatch Logs** (quick debugging; can get expensive at scale)

---

## 8. Security Headers at the Edge (CloudFront Response Headers Policy)

Attach a **Response Headers Policy** to web (and optionally API).

### Recommended headers

| Header | Value / notes |
|--------|----------------|
| **Strict-Transport-Security** | max-age=31536000; includeSubDomains; preload (use preload only if you’re sure) |
| **X-Content-Type-Options** | nosniff |
| **X-Frame-Options** | DENY (or SAMEORIGIN if you embed) |
| **Referrer-Policy** | strict-origin-when-cross-origin |
| **Permissions-Policy** | Restrict camera/mic/geolocation unless needed |
| **Content-Security-Policy (CSP)** | Start in Report-Only in staging, then enforce in prod once stable; keep compatible with Next.js scripts/fonts; tighten over time |

---

## 9. DNS & Certificates (ACM + Route53)

### 9.1 Certificates

- **CloudFront:** ACM cert in **us-east-1**; SANs for app.example.com and api.example.com.
- **ALB (later):** Cert in the deployment region.

### 9.2 Route53 records

- **A/AAAA Alias:** app.example.com → CloudFront; api.example.com → CloudFront (preferred) or ALB DNS (later).
- **ACM validation:** DNS validation records created via Terraform automatically.

---

## 10. Logging & Observability (Edge layer)

### 10.1 CloudFront logs

- **S3 logging bucket:** Block public access; SSE; lifecycle: transition to IA, expire after retention window.

### 10.2 Metrics & alarms (baseline)

- **CloudFront:** 4xx/5xx error rate alarms; origin latency alarms.
- **WAF:** Blocked request rate spike alerts.
- (Later) Integrate with dashboards in M10.

---

## 11. Terraform Implementation (Modules + Live Stacks)

### 11.1 New module: `modules/edge`

**Includes**

- Route53 records (optional, if zone managed here)
- ACM certs (us-east-1 provider alias for CloudFront cert)
- S3 web bucket + policy + OAC access
- CloudFront distribution(s)
- CloudFront cache policies + origin request policies
- Response headers policy
- WAF WebACL + associations
- Logging buckets + policies

### 11.2 Providers (important)

Use **two AWS providers** in Terraform:

- **Primary region** (e.g. us-east-1 or your main region)
- **us-east-1 provider alias** for ACM cert used by CloudFront

Example pattern:

```hcl
provider "aws" { region = var.region }

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}
```

### 11.3 Live stack structure

Create:

- `infra/terraform/live/dev/edge/`
- `infra/terraform/live/staging/edge/`
- `infra/terraform/live/prod/edge/`

**Backend keys:** e.g. `chatbot/dev/edge/terraform.tfstate`

### 11.4 Key outputs

- CloudFront distribution IDs/domains
- WAF WebACL ARN
- Web bucket name
- Deployed domain URLs

---

## 12. Operational Runbooks (M5)

### Runbook: “Deploy new frontend version”

1. Build Next.js (static) in CI.
2. Upload artifacts to S3 (versioned path or replace).
3. Create **CloudFront invalidation:** invalidate `/*` or only index.html/manifest depending on caching strategy.

### Runbook: “WAF false positives”

1. Inspect WAF logs for rule IDs causing blocks.
2. Add **scoped exclusions** (URI-based) rather than disabling entire rule group.
3. Roll changes via Terraform (tracked).

### Runbook: “Emergency maintenance mode”

- **Pattern 1:** CloudFront origin failover group (if API origin down, serve static “maintenance”).
- **Pattern 2:** Update distribution behavior to route to a maintenance S3 origin (fast rollback).

### Runbook: “TLS / cert renewal”

- ACM renews automatically for DNS-validated certs.
- Monitor certificate expiration alarms (optional).

---

## 13. M5 Definition of Done (Acceptance Checklist)

- [ ] app.example.com serves the web via CloudFront with HTTPS enforced
- [ ] S3 origin is private (OAC), no public bucket access
- [ ] WAF attached, managed rules enabled, rate limiting active
- [ ] Security headers policy applied (at least HSTS / nosniff / referrer-policy)
- [ ] Logs: CloudFront logs delivered to S3; WAF logs enabled (S3 via Firehose or CW Logs)
- [ ] Terraform module **edge** created + live stacks for dev/staging/prod
- [ ] Documented deploy + rollback procedure for frontend releases
