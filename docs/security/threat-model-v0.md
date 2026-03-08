# Threat Model — v0 (Baseline)

## Scope

This is the initial threat model for the chatbot platform, covering
the attack surface defined in M0 (NFR spec). It will be refined as
the platform evolves.

## Assets

| Asset                    | Sensitivity | Storage             |
|--------------------------|-------------|---------------------|
| User chat messages       | High (PII)  | DynamoDB (encrypted) |
| Conversation metadata    | Medium      | DynamoDB (encrypted) |
| User credentials/tokens  | Critical    | Cognito + JWT        |
| LLM provider API keys    | Critical    | Secrets Manager      |
| Uploaded attachments     | High        | S3 (SSE-KMS)        |

## Threat Categories

### 1. Authentication & Identity

| Threat                              | Mitigation                                      |
|-------------------------------------|------------------------------------------------|
| Stolen/leaked JWT                   | Short token lifetimes, refresh flow, HTTPS only |
| Brute-force login                   | Cognito lockout policies, WAF rate limits       |
| Token replay                        | JWT expiration, audience validation              |

### 2. Authorization & Tenant Isolation

| Threat                              | Mitigation                                      |
|-------------------------------------|------------------------------------------------|
| Cross-tenant data access            | tenant_id in all queries, enforced in middleware |
| Privilege escalation                | RBAC enforcement, no wildcard permissions        |
| Direct object reference (IDOR)      | Authorization checks on every resource access    |

### 3. Input & Injection

| Threat                              | Mitigation                                      |
|-------------------------------------|------------------------------------------------|
| Prompt injection                    | Input validation, guardrails (future milestone)  |
| XSS via chat content                | Output encoding in frontend, CSP headers         |
| API abuse (large payloads)          | Request size limits, WAF rules                   |

### 4. Infrastructure

| Threat                              | Mitigation                                      |
|-------------------------------------|------------------------------------------------|
| DDoS                                | CloudFront + WAF rate-based rules                |
| Exposed internal services           | Private subnets, security groups, VPC endpoints  |
| Secrets in code/logs                | Secret scanning (gitleaks), log redaction         |
| Container vulnerabilities           | Trivy scanning, minimal base images              |

### 5. Data

| Threat                              | Mitigation                                      |
|-------------------------------------|------------------------------------------------|
| Data exfiltration                   | Encryption at rest (KMS), VPC endpoints          |
| PII in logs                         | Structured logging with redaction rules          |
| Uncontrolled data retention         | TTL policies, tenant-configurable retention      |

## Open Items

- Detailed prompt injection mitigation strategy (M13 — Tool/Plugin Framework)
- Dependency supply chain hardening (M16 — Security Hardening v2)
- Incident response playbook (M18 — FinOps + SLO Operations)
