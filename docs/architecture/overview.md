# Architecture Overview

## System Summary

The chatbot platform is a **multi-tenant**, **production-grade** system built on AWS
that supports thousands of concurrent users with SSE streaming responses.

## High-Level Components

```
┌─────────────┐     ┌──────────────┐     ┌────────────────┐
│  CloudFront  │────▶│   ALB        │────▶│  ECS Fargate   │
│  + WAF       │     │              │     │  (chat-api)    │
└─────────────┘     └──────────────┘     └────────┬───────┘
                                                   │
                    ┌──────────────┐     ┌─────────▼───────┐
                    │  DynamoDB    │◀────│   Redis          │
                    │  (state)     │     │   (cache/limits) │
                    └──────────────┘     └─────────────────┘
                                                   │
                    ┌──────────────┐     ┌─────────▼───────┐
                    │  SQS         │────▶│  ECS Fargate     │
                    │  (job queue) │     │  (chat-worker)   │
                    └──────────────┘     └─────────────────┘
```

## Service Boundaries

| Service       | Responsibility                                  |
|---------------|------------------------------------------------|
| **chat-api**  | REST/SSE API, auth validation, orchestration    |
| **chat-worker** | Async jobs (ingestion, embeddings, tools)     |
| **web**       | Next.js frontend, served via CloudFront         |

## Key Design Principles

1. **Stateless API** — All durable state in DynamoDB/S3/Redis; API tasks can scale freely.
2. **Multi-tenant from day 1** — `tenant_id` in every key, path, and claim.
3. **Provider-agnostic** — `LLMProvider` interface supports OpenAI, Bedrock, Anthropic.
4. **Security by default** — Encryption at rest (KMS), in transit (TLS), WAF, rate limits.
5. **Observable** — Structured JSON logs, correlation IDs, metrics, traces.

## Technology Stack

| Layer         | Technology                              |
|---------------|----------------------------------------|
| Frontend      | Next.js (TypeScript)                    |
| API           | FastAPI (Python 3.11+)                  |
| Worker        | Python (SQS consumer)                   |
| Data          | DynamoDB, S3, ElastiCache Redis         |
| Auth          | Cognito (OIDC/JWT)                      |
| Infrastructure| Terraform, ECS Fargate, CloudFront      |
| CI/CD         | GitHub Actions                          |

## Further Reading

- [ADR: Monorepo & Tooling](adr/0001-monorepo-and-tooling.md)
- [Local Development Guide](../runbooks/local-dev.md)
- [CI/CD Guide](../runbooks/ci-cd.md)
