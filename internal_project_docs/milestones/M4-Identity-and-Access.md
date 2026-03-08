# M4 — Identity & Access Baseline (AuthN/AuthZ + IAM Least Privilege) — Technical Design v1

M4 establishes who can use the platform (authentication), what they can do (authorization), and how services access AWS (IAM). This is where we lock in multi-tenant identity, RBAC/ABAC, token claims, and secure secret handling so every later milestone inherits strong guardrails.

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- **End-user authentication** (web) with secure JWTs.
- **Multi-tenant authorization** enforced consistently across APIs/data.
- **Admin access model** (tenant admin + platform admin).
- **Least-privilege IAM** for ECS services (API/worker/web).
- **No long-lived credentials** in CI or services; all secrets managed.

### Non-goals (later milestones)

- SCIM provisioning, SSO (SAML) for enterprise tenants (later)
- Fine-grained row-level entitlements beyond tenant/user/role (later)
- Full audit lake & SIEM integrations (later)

### Outcomes (end of M4)

- **Cognito** (or OIDC provider) configured + Next.js login flow.
- **JWT validation** implemented in backend.
- **Tenant/user/role claims** standardized.
- **IAM roles** created for ECS tasks (execution + task roles) with least privileges.
- **Secrets Manager** patterns defined for provider keys and sensitive config.

---

## 2. Key Decisions (Recommended Defaults)

### 2.1 Identity Provider

**Recommended:** Amazon Cognito User Pool (OIDC) for end users.

**Why:** AWS-native, integrates cleanly with Terraform, supports MFA, token customization via Lambda triggers.

### 2.2 Where to enforce auth

- **Backend (FastAPI)** validates JWT on every request (recommended).
- Keep **ALB “dumb”** (no OIDC at ALB) to avoid edge cases with SSE and to keep logic consistent across all clients.

### 2.3 Multi-tenant strategy

- **Single User Pool** for all tenants (recommended).
- Tenant boundaries enforced via:
  - Custom claim **`tenant_id`** in token
  - Every DB key includes `tenant_id` (DynamoDB partitioning)
  - Every API call checks `tenant_id` match

---

## 3. Identity Model (User, Tenant, Role, Plan)

### 3.1 Core entities

| Entity | Attributes |
|--------|------------|
| **Tenant** | tenant_id, name, plan_tier, quotas, feature flags |
| **User** | user_id (Cognito sub), email, status; membership: tenant_id; roles: user \| tenant_admin \| platform_admin |
| **Policy inputs** | tenant_id, user_id, roles[], plan_tier, features[] |

### 3.2 Where each lives

| Store | Purpose |
|-------|---------|
| **Cognito** | Authentication, passwords/MFA, user lifecycle |
| **DynamoDB** (M7, defined now) | Tenant/user mapping + roles + quotas: **Tenants** table, **TenantUsers** table (maps cognito sub → tenant_id + roles) |

---

## 4. Token Claims Standard (Contract)

### 4.1 Required JWT claims (platform contract)

Must be available for every authenticated request:

| Claim | Description |
|-------|-------------|
| `sub` | Cognito user ID (immutable) |
| `iss`, `aud`, `exp`, `iat` | Standard |
| `custom:tenant_id` (or `tenant_id`) | Injected |
| `roles` | Array or string list (e.g. `["user"]`, `["tenant_admin"]`) |
| `plan_tier` | Optional (quota enforcement) |
| `features` | Optional (feature flags) |

### 4.2 How to inject tenant/roles into tokens

**Recommended:** **Cognito Pre Token Generation Lambda trigger**:

- Looks up `sub` in DynamoDB **TenantUsers**
- Injects `tenant_id`, `roles`, `plan_tier`, `features` into token claims
- Denies token issuance if user is disabled or not mapped

This avoids Cognito Groups exploding in size (groups-per-tenant doesn’t scale cleanly with many tenants).

---

## 5. Authentication Flows (Web)

### 5.1 Next.js login

| Option | Approach |
|--------|----------|
| **A — Cognito Hosted UI** (fastest, secure) | Next.js redirects to Cognito domain; Authorization Code + PKCE; Cognito returns code → exchange for tokens; store access token securely (prefer HttpOnly cookies via Next.js server routes) |
| **B — NextAuth.js with Cognito provider** | NextAuth handles OAuth code exchange; session stored server-side / encrypted cookies |

### 5.2 Security baseline

- Use **Authorization Code + PKCE** (never implicit flow).
- **Access tokens** short-lived (e.g. 15–60 minutes).
- **Refresh tokens** longer (e.g. 30 days) with rotation strategy.

---

## 6. Backend Authorization (FastAPI)

### 6.1 JWT verification (required checks)

Backend middleware must verify:

- Signature via **Cognito JWKS**
- `iss` matches your user pool
- `aud` matches your client/app audience
- `exp` not expired
- **`tenant_id`** present
- (Optional) token use = access token (not id token)

### 6.2 Authorization policy (RBAC + tenant boundary)

Every request computes an **AuthContext:** `tenant_id`, `user_id`, `roles[]`.

**Rules**

- **Tenant-scoped endpoints:** require `resource.tenant_id == token.tenant_id`
- **Admin endpoints:** require `tenant_admin` role (or `platform_admin`)
- **Platform admin endpoints:** isolated, only for internal ops

### 6.3 Recommended endpoint scoping

| Path pattern | Requirement |
|--------------|-------------|
| `/v1/tenant/*` | Any authenticated user; tenant boundary enforced |
| `/v1/admin/tenant/*` | `tenant_admin` |
| `/v1/admin/platform/*` | `platform_admin` |

### 6.4 Error model (consistent)

| Code | Meaning |
|------|---------|
| **401 Unauthorized** | Token missing/invalid/expired |
| **403 Forbidden** | Token valid but lacks role or tenant boundary fails |
| **429 Too Many Requests** | Quota/rate limit exceeded (M8, but contract now) |

---

## 7. AWS IAM Model (Services)

### 7.1 Roles (minimum)

For each ECS service:

| Role | Purpose |
|------|----------|
| **Execution Role** (ECS agent) | Pulls images from ECR; writes logs to CloudWatch; reads secrets if configured via task definition (optional) |
| **Task Role** (app runtime identity) | Used by AWS SDK in code; must be least privilege for only what that service needs |

### 7.2 Least privilege examples (conceptual)

| Service | Task role (eventually) |
|---------|------------------------|
| **chat-api** | Read/write DynamoDB (conversations/messages/requests); read Secrets Manager (LLM keys); write CloudWatch metrics (EMF); read/write S3 attachments (tenant prefixes) |
| **chat-worker** | Consume SQS (M12); read/write S3 ingestion; write DynamoDB job status |
| **web** (if SSR in ECS) | Generally none unless SSR calls AWS directly (usually it shouldn’t) |

### 7.3 IAM policy patterns (recommended)

- Prefer **resource-level restrictions** (specific table ARNs, bucket/prefix).
- Use **conditions** on: `aws:RequestedRegion`, `s3:prefix` for tenant boundaries (when possible), `kms:ViaService` for KMS (optional).

---

## 8. Secrets & Configuration (Mandatory Baseline)

### 8.1 What is a secret

- OpenAI/Bedrock keys (if applicable)
- OAuth client secrets (if any)
- Encryption salts, signing keys (if you manage any)
- DB passwords (Aurora later)

### 8.2 Storage and injection

| Store | Use |
|-------|-----|
| **AWS Secrets Manager** | Secrets |
| **SSM Parameter Store** | Non-secrets (feature flags, config defaults) |
| **ECS task definition** | References secrets (not env files) |
| **Local** | Developers use `.env` only for local compose; never in git |

### 8.3 Rotation baseline

- Define rotation strategy (manual now, automated later).
- No secret should require **rebuilding containers** to rotate.

---

## 9. Audit Logging (Identity + Admin Actions)

### 9.1 What to audit (minimum)

- Tenant creation / update
- Role changes
- Quota/feature changes
- User disable/enable
- Auth failures (rate-limited log volume)

### 9.2 Where it goes (baseline)

- **Structured logs** to CloudWatch.
- (Optional) DynamoDB **AuditEvents** table later for query/reporting.

**Audit event fields:** `event_id`, `ts`, `actor_user_id`, `actor_roles`, `tenant_id`, `action`, `target`, `request_id`, `ip_hash`

---

## 10. Terraform Implementation (M4 stacks/modules)

### 10.1 Suggested modules

| Module | Contents |
|--------|----------|
| **modules/auth-cognito/** | User pool, app clients, domain, hosted UI, Lambda triggers, IAM for triggers |
| **modules/iam-service-roles/** | ECS execution role policy; per-service task role policies (parameterized) |
| **modules/secrets/** | Secrets skeleton + KMS key usage pattern |

### 10.2 Live stack layout

Create:

```
infra/terraform/live/{dev,staging,prod}/foundation/
  auth.tf          # cognito + triggers
  iam.tf           # task roles baseline
  secrets.tf       # secret placeholders (no values)
  outputs.tf
```

### 10.3 Cognito resources (high level)

- `aws_cognito_user_pool` — password policy, MFA config (optional required in prod), account recovery rules
- `aws_cognito_user_pool_client` — auth code flow + PKCE, refresh token settings
- `aws_cognito_user_pool_domain`
- `aws_lambda_function` (pre-token-generation trigger)
- `aws_lambda_permission` (allow Cognito invoke)
- **IAM role for Lambda** + DynamoDB read access (TenantUsers)

---

## 11. Security Baseline Settings (Recommended Defaults)

### Cognito

- **Password policy:** Strong minimums
- **MFA:** dev = optional; prod = required for admins (at least)
- Prevent user enumeration where possible
- Email verification required

### Tokens

- **Access token TTL:** 15–60 min
- **Refresh token TTL:** 30 days (tune per product)
- Use **PKCE** always

### Admin separation

| Option | Description |
|--------|-------------|
| **1 (recommended later)** | Platform admin uses IAM Identity Center and separate admin portal auth |
| **2 (acceptable now)** | `platform_admin` role in Cognito but heavily restricted |

---

## 12. M4 Definition of Done (Acceptance Checklist)

- [ ] Cognito User Pool + App Client configured for auth code + PKCE
- [ ] Next.js can sign in and obtain tokens (or NextAuth integrated)
- [ ] Backend verifies JWT correctly and rejects invalid/expired tokens
- [ ] Tenant boundary enforced (`tenant_id` claim required; mismatches → 403)
- [ ] Roles enforced for admin endpoints
- [ ] ECS execution/task role templates exist (even if services deployed later)
- [ ] Secrets Manager pattern defined and no secrets exist in git/TF state
- [ ] Audit log structure agreed and emitted for admin actions
