# M19 — Enterprise Security & Compliance v1 (SSO, SCIM, RBAC/ABAC, Audit Immutability, Data Residency, SOC2-Ready Controls) — Technical Design v1

M19 upgrades your platform from “secure SaaS” to “enterprise-ready.” The core theme is **governance:** identity lifecycle, least-privilege access, immutable auditing, data controls, and evidence that your controls work (SOC2-aligned).

This milestone assumes: M4 (auth), M10 (observability), M15–M16 (billing/payments), M17 (reliability), M13–M14 (tools/RAG).

---

## 0. Goals, Non-Goals, Outcomes

### Goals

- **SSO** for tenant orgs (SAML 2.0 / OIDC) with enforced MFA via IdP.
- **SCIM provisioning** (users/groups) + deprovisioning (near-real-time access revocation).
- **Enterprise authorization:** orgs, workspaces, roles; fine-grained scopes for tools/RAG/admin.
- **Immutable audit logs** (tamper-evident + exportable).
- **Data governance:** retention policies, legal hold (v1), deletion workflows.
- **Data residency:** region pinning + restricted egress.
- **Encryption hardening:** KMS patterns, optional BYOK.
- **SOC2-ready operational controls:** access reviews, change management, incident evidence, vulnerability management.

### Non-Goals (later)

- Full DLP content inspection / ML-based PII detection (v2)
- Customer-managed key per tenant with external key stores (advanced BYOK/HYOK)
- FedRAMP-level controls (separate program)

### Outcomes

- Enterprise tenants can enforce **SSO** and **provision users** automatically.
- Admins can prove “who did what, when” with **immutable audit trails**.
- You can satisfy most **enterprise security questionnaires** credibly and consistently.

---

## 1. Architecture Overview

### Identity plane

- **Auth provider:** Auth0/Okta CIC (fastest SSO + SCIM) **or** Amazon Cognito + external IdPs (SAML/OIDC) + your SCIM service. SSO sits above existing JWT-based auth (M4).

### Governance plane

- **Org/workspace model** + roles/scopes in DynamoDB (or relational later). **Policy engine** enforces authorization for: chat endpoints, tools (M13), RAG (M14), admin/billing (M15–M16).

### Audit plane

- Real-time audit events → **DynamoDB** (queryable) + **S3 Object Lock** (immutable archive) + optional external export.

### Data plane controls

- Region pinning, restricted egress, encryption, retention, deletion workflows.

---

## 2. Tenant/Org Model (Enterprise multi-tenancy foundation)

### 2.1 Entities

- **Tenant (Org):** company/customer
- **Workspace** (optional v1, recommended): partitions data/config within tenant
- **User**, **Group** (from SCIM), **Role** (collection of permissions)
- **Policy bindings:** role assignments to users/groups within tenant/workspace

### 2.2 RBAC + light ABAC

- **RBAC:** roles grant permission scopes.
- **ABAC:** resource attributes enforce boundaries: tenant_id, workspace_id, doc_id, conversation_id, tool_name.

---

## 3. SSO (SAML 2.0 / OIDC) — v1 Design

### 3.1 Requirements

- Tenant can enable: **SAML** (Okta/Azure AD) or **OIDC** (Google Workspace / Entra ID).
- Tenant can enforce: **SSO-only** login; **domain allowlist** (e.g. @company.com); **IdP-managed MFA**.
- Support: **JIT provisioning** or **SCIM** (SCIM preferred).

### 3.2 Implementation patterns

| Pattern | Description |
|--------|-------------|
| **A — Auth0/Okta CIC** | Enterprise connection per tenant (SAML/OIDC); normalized profile + groups/roles. Best for speed + enterprise features. |
| **B — Cognito** | User Pool + federated IdPs; you maintain tenant-id mapping and group logic; you implement SCIM. AWS-native + cost control; more build. |

**Recommendation:** Auth0/Okta CIC for “best-of-best” quickly; Cognito for AWS-native and long-term cost control.

### 3.3 Tenant SSO config model

**Table: tenant_identity_providers**

- PK = `TENANT#{tenant_id}`, SK = `IDP#{idp_id}`
- **Fields:** type (saml\|oidc), issuer, sso_url, x509_cert (SAML) or client_id, discovery_url (OIDC), enforced (bool), allowed_domains, jit_provisioning, group_claim_mapping, created_at, updated_at

### 3.4 Session/token strategy

- API still trusts **JWT** (M4). Token must include: tenant_id, user_id, roles/scopes (or reference), **auth_method** (sso\|password\|api_key). Short-lived access + refresh (browser) or existing approach.

---

## 4. SCIM Provisioning (Users + Groups + Deprovisioning)

### 4.1 Why SCIM matters

- Automatic onboarding/offboarding, group sync, role enforcement. **Deprovisioning** prevents ghost accounts.

### 4.2 SCIM service components

- **scim-api** (separate service or chat-api with strict routing). **Endpoints (v1):** POST/PATCH/DELETE /scim/v2/Users; POST/PATCH /scim/v2/Groups. **Auth:** Per-tenant SCIM bearer token in Secrets Manager; allowed only from tenant’s IdP or token (not IP alone).

### 4.3 Provisioning workflow

- User created/updated → tenant_users; Group → tenant_groups; membership → user_group_memberships. **Deprovision:** mark user DISABLED; revoke sessions (4.4); remove tool/job access.

### 4.4 Immediate access revocation (critical)

- **Option:** **token_revocation_version** (or auth_version) per user: JWT contains version; API checks cached value in Redis. **Recommendation:** user **auth_version** integer; increment on disable/password reset; API rejects tokens with old version (fast Redis lookup).

---

## 5. Authorization: Roles, Scopes, and Tool/RAG Governance

### 5.1 Permission scopes (expand from M13)

- conversation:read|write|delete  
- rag:doc:upload|read|delete|reindex  
- tools:use:{tool_name} (fine-grained)  
- jobs:create|cancel|view  
- billing:view|manage  
- admin:tenant|admin:workspace|admin:security  

### 5.2 Role model

- **Table: tenant_roles** — PK = `TENANT#{tenant_id}`, SK = `ROLE#{role_id}`; name, description, scopes[]  
- **Table: tenant_role_bindings** — binds role_id to user_id or group_id; optionally scoped to workspace  

### 5.3 Enforce in code

- **Central policy engine:** authorize(ctx, action, resource) → allow/deny. Every endpoint + tool execution calls it. Tool framework (M13): tool definitions list required scopes; router denies if missing.

### 5.4 RAG access control (v1)

- **v1:** Tenant-scoped docs (all users in tenant can read). **Enterprise v1+:** doc visibility ALL_TENANT | WORKSPACE | GROUP | PRIVATE; store ACL on rag_documents; retrieval filter on allowed doc_ids (cached).

---

## 6. Immutable Audit Logging (Enterprise-grade)

### 6.1 Two-layer audit storage

- **Queryable** audit table (fast, short–medium retention).
- **Immutable archive** in S3 with **Object Lock** (WORM).

### 6.2 Audit event schema

**Event types:** auth (login, SSO enforced, token revoked); admin (role changes, SSO config, plan changes); data access (doc upload/delete, export, RAG retrieval metadata); tool calls (tool name + outcome, no sensitive payload); billing (subscription/invoice high-level).

**Fields:** event_id, occurred_at, tenant_id, workspace_id, actor_type (user|service|system), actor_user_id_hash, action, resource_type, resource_id, result (success|denied|error), request_id, trace_id, ip_hash, user_agent_hash.

### 6.3 S3 Object Lock archive

- **Bucket:** audit-archive-&lt;env&gt;. **Enable:** Versioning, **Object Lock (Compliance mode)** with retention (e.g. 1–7 years). **Write pattern:** daily/hourly partitioned, e.g. s3://.../tenant=&lt;id&gt;/yyyy/mm/dd/audit_&lt;hh&gt;.jsonl.gz. Tampering extremely difficult; strong enterprise signal.

### 6.4 Audit export APIs

- **GET /v1/admin/audit/events?from=&amp;to=&amp;action=&amp;actor=...** (queryable store).  
- **POST /v1/admin/audit/export** → async job → signed URL to S3 export.

---

## 7. Data Governance: Retention, Deletion, Legal Hold

### 7.1 Retention policies per tenant

**Table: tenant_data_policies**

- Retention days for: conversations/messages, RAG docs/artifacts, audit logs (queryable), billing events; “do not train” flags; export controls.

### 7.2 Deletion workflows

- **POST /v1/admin/data/delete-user** (DSR), **POST /v1/admin/data/delete-tenant** (contract termination). Both become **M12 jobs** that: delete or anonymize per policy; write audit entries; produce completion reports.

### 7.3 Legal hold (v1 minimal)

- **legal_hold** flag on tenant prevents deletion jobs from removing protected data. Audit and billing data often excluded from deletion (configurable).

---

## 8. Data Residency &amp; Egress Control

### 8.1 Region pinning

- Tenant chooses **primary_region** and optional **allowed_regions[]**. System enforces: RAG storage, vector store, Dynamo tables in that set; API deploys tenant only to permitted regions (or separate stacks per region).

### 8.2 Egress restriction

- For “strict residency” tenants: disable non-AWS external egress; require **AWS-native provider** (e.g. Bedrock). Enforce with VPC endpoints; NAT disabled or tightly controlled. **Tenant policy:** external_provider_allowed=false.

---

## 9. Encryption &amp; Key Management Hardening

### 9.1 Baseline (required)

- DynamoDB SSE-KMS; S3 SSE-KMS with bucket policies; Secrets in Secrets Manager; TLS everywhere (CloudFront → ALB → ECS).

### 9.2 Tenant-isolated keys (enterprise add-on)

- **Option:** per-tenant KMS CMK (strong isolation, easier rotation; key sprawl). **v1 compromise:** per-environment CMKs + IAM boundaries; per-tenant keys only for top enterprise tier.

### 9.3 Key rotation

- Secrets rotation (Stripe, SCIM tokens); KMS key rotation enabled; documented rotation runbook + tests.

---

## 10. Secure SDLC &amp; Compliance Controls (SOC2-aligned evidence)

### 10.1 Access controls

- SSO for internal admin accounts; least-privilege IAM + permission boundaries; break-glass role with strict logging and approvals.

### 10.2 Change management

- Branch protections; PR reviews; CI (unit, integration, IaC lint); Terraform plan review and apply controls; deployment approvals for prod.

### 10.3 Vulnerability management

- Container image scanning (ECR enhanced or equivalent); SCA in CI; patch cadence and SLA (e.g. critical CVEs in 7 days).

### 10.4 Security monitoring

- GuardDuty; CloudTrail org trail + immutable storage; alerts to on-call (M17).

### 10.5 Incident response evidence

- Incident templates; postmortems; access logs and audit exports; DR drill records (M17).

---

## 11. Terraform / Infrastructure Additions (M19)

### New modules

| Module | Contents |
|--------|----------|
| **modules/enterprise_identity** | SSO config (Cognito or placeholders for Auth0); Secrets for SCIM tokens |
| **modules/enterprise_scim** | API routes + WAF for /scim/*; optional separate ECS service |
| **modules/audit_immutable** | DynamoDB audit_events; S3 Object Lock bucket + lifecycle + KMS; optional Firehose |
| **modules/data_policies** | Tenant policies table + config distribution |
| **modules/security_baseline_enterprise** | CloudTrail, GuardDuty, Security Hub (optional), config rules (optional) |

### ECS changes

- AUDIT_ARCHIVE_BUCKET, TENANT_POLICY_CACHE_TTL, AUTH_VERSION_CHECK_ENABLED=true.

---

## 12. Testing Strategy (Enterprise-grade)

### 12.1 Security tests

- **Cross-tenant:** conversations, docs, tool calls, billing. **SCIM:** create user, disable user, access revoked immediately. **SSO:** password login blocked when enforced; domain allowlist enforced.

### 12.2 Audit integrity tests

- Every sensitive action emits audit event; export job produces immutable archive; Object Lock prevents deletion/overwrite.

### 12.3 Compliance evidence tests

- Prove logs exist for: admin role changes, subscription state changes, data deletion. Prove least privilege (IAM, Access Analyzer).

---

## 13. Definition of Done (M19 acceptance checklist)

- [ ] SSO (SAML/OIDC) supported per tenant with enforcement + domain allowlist
- [ ] SCIM provisioning: users + groups; deprovision revokes access within minutes (or faster)
- [ ] Central policy engine enforces RBAC/ABAC across API, tools, RAG, admin actions
- [ ] Immutable audit archive in S3 Object Lock + queryable store + export flow
- [ ] Tenant data policies (retention/deletion/legal hold) + deletion jobs audited
- [ ] Data residency (region pinning + egress restrictions)
- [ ] Encryption hardened (SSE-KMS everywhere, rotation runbooks)
- [ ] SOC2-aligned operational controls documented and implemented (change mgmt, vuln mgmt, incident evidence)
- [ ] Tests cover cross-tenant, SSO/SCIM, audit completeness, and revocation correctness
