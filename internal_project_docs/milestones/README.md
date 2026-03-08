# Milestones

Technical specs for each milestone of the chatbot platform. Each milestone builds on the previous.

| Milestone | Document | Outcome |
|-----------|----------|---------|
| M0 | [M0-Product-and-NFRs.md](./M0-Product-and-NFRs.md) | Product & NFR technical spec (scale, latency, security, SLOs) |
| M1 | [M1-Repo-and-Engineering-Standards.md](./M1-Repo-and-Engineering-Standards.md) | Repo + CI skeleton |
| M2 | [M2-Terraform-Foundation.md](./M2-Terraform-Foundation.md) | Terraform foundation + remote state |
| M3 | [M3-Network-Baseline.md](./M3-Network-Baseline.md) | VPC, subnets, endpoints |
| M4 | [M4-Identity-and-Access.md](./M4-Identity-and-Access.md) | AuthN/AuthZ baseline |
| M5 | [M5-Edge-and-Frontend-Delivery.md](./M5-Edge-and-Frontend-Delivery.md) | CloudFront + WAF |
| M6 | [M6-Core-Chat-API-v1.md](./M6-Core-Chat-API-v1.md) | Core Chat API (streaming) |
| M7 | [M7-Conversation-Storage-v1.md](./M7-Conversation-Storage-v1.md) | Durable state + idempotency |
| M8 | [M8-Redis-Layer-v1.md](./M8-Redis-Layer-v1.md) | Rate limits + ephemeral state |
| M9 | [M9-ECS-Fargate-Productionization.md](./M9-ECS-Fargate-Productionization.md) | ECS/Fargate + autoscaling |
| M10 | [M10-Observability-v1.md](./M10-Observability-v1.md) | Logs, metrics, traces, alarms |
| M11 | [M11-Load-Testing-and-Performance-Tuning.md](./M11-Load-Testing-and-Performance-Tuning.md) | Load testing + tuning gate |
| M12 | [M12-Async-Jobs-Platform.md](./M12-Async-Jobs-Platform.md) | Workers + queues |
| M13 | [M13-Tool-Plugin-Framework-v1.md](./M13-Tool-Plugin-Framework-v1.md) | Tool/plugin framework |
| M14 | [M14-RAG-v1.md](./M14-RAG-v1.md) | RAG + ingestion pipeline |
| M15 | [M15-Multi-Tenant-Hardening.md](./M15-Multi-Tenant-Hardening.md) | Multi-tenant hardening |
| M16 | [M16-Security-Hardening-v2.md](./M16-Security-Hardening-v2.md) | Security hardening v2 |
| M17 | [M17-Reliability-and-DR.md](./M17-Reliability-and-DR.md) | Reliability & DR |
| M18 | [M18-FinOps-and-SLO-Operations.md](./M18-FinOps-and-SLO-Operations.md) | Cost optimization + FinOps |
| M19 | [M19-Enterprise-Security-and-Compliance-v1.md](./M19-Enterprise-Security-and-Compliance-v1.md) | Enterprise security & compliance (SSO, SCIM, audit, SOC2-ready) |

M0–M19 contain full technical specs (architecture, Terraform, data models, API spec, security, testing, runbooks). Execute the ladder milestone by milestone.
