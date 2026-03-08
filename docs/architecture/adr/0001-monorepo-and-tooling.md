# ADR-0001: Monorepo and Tooling Choices

**Status:** Accepted
**Date:** 2026-02-07

## Context

We need to establish a repository structure and tooling baseline for a platform
that includes a Python API, a Python background worker, a Next.js frontend,
and Terraform infrastructure code.

## Decision

### Monorepo

We will use a **single monorepo** with clear directory boundaries:

- `apps/web` — Next.js frontend
- `services/chat-api` — FastAPI chat API
- `services/chat-worker` — Async background worker
- `infra/terraform` — Infrastructure as Code
- `packages/` — Shared contracts and libraries

**Rationale:** Atomic commits across API/frontend/infra, simplified CI, shared
tooling, and easier onboarding.

### Python Tooling

- **Package manager:** uv (fast, lockfile-based)
- **Formatter + Linter:** Ruff (replaces black, isort, flake8)
- **Type checker:** mypy
- **Tests:** pytest + pytest-cov + pytest-asyncio
- **Target version:** Python 3.11+

### Node.js Tooling

- **Framework:** Next.js 15 (App Router)
- **Language:** TypeScript (strict mode)
- **Linter:** ESLint with Next.js config
- **Formatter:** Prettier
- **Tests:** Vitest + Testing Library
- **Target version:** Node.js 20 LTS

### Docker

- Multi-stage builds
- Non-root runtime user
- Pinned major versions of base images
- Health checks for API services

### CI

- GitHub Actions
- Separate workflows for CI (lint/test/build) and Security (scanning/audits)
- Pre-commit hooks for local fast feedback

## Consequences

- Engineers must have Docker, Python 3.11+, Node 20+, uv, and Terraform installed locally.
- All code quality gates are enforced in CI — nothing merges without green checks.
- Adding a new service means creating a new directory under `services/` with the
  same structure and adding it to the CI matrix.
