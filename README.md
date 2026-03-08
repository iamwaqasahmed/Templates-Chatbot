# Chatbot Platform

Production-grade, multi-tenant chatbot platform on AWS.

- **Frontend:** Next.js (TypeScript) — `apps/web/`
- **API:** FastAPI (Python) with SSE streaming — `services/chat-api/`
- **Worker:** Async background jobs — `services/chat-worker/`
- **Infrastructure:** Terraform — `infra/terraform/`

---

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) & Docker Compose
- [Python 3.11+](https://www.python.org/) & [uv](https://github.com/astral-sh/uv)
- [Node.js 20+](https://nodejs.org/) & npm
- [Terraform 1.5+](https://www.terraform.io/)
- [pre-commit](https://pre-commit.com/)

### Local Development

```bash
# Clone and set up pre-commit hooks
git clone <repo-url> && cd chatbot-platform
pre-commit install

# Start all services (web + api + worker + redis + dynamodb-local)
make up

# View logs
make logs
```

| Service       | URL                        |
|---------------|----------------------------|
| Web (Next.js) | http://localhost:3000       |
| Chat API      | http://localhost:8001       |
| API Docs      | http://localhost:8001/docs  |

### Common Commands

```bash
make lint      # Run linters (Python + Next.js)
make format    # Auto-format code
make test      # Run all tests
make build     # Build Docker images
make up        # Start local environment
make down      # Stop local environment
```

---

## Repository Structure

```
chatbot-platform/
  apps/
    web/                     # Next.js frontend
  services/
    chat-api/                # FastAPI — chat API + SSE streaming
    chat-worker/             # Async background worker
  packages/
    shared-contracts/        # Shared types/schemas
  infra/
    terraform/               # IaC (modules + live environments)
    scripts/                 # Bootstrap and utility scripts
  deploy/
    compose/                 # Docker Compose for local dev
    docker/                  # Shared Dockerfiles
  docs/
    architecture/            # Architecture docs + ADRs
    runbooks/                # Operational runbooks
    security/                # Security docs
  .github/
    workflows/               # CI/CD pipelines
```

---

## Engineering Standards

- **Branching:** `main` (protected) + `feature/*`, `fix/*`, `chore/*`
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/)
- **Python:** Ruff (lint + format), mypy (types), pytest (tests)
- **TypeScript:** ESLint + Prettier, Vitest (tests)
- **Docker:** Multi-stage builds, non-root runtime, pinned base images
- **Terraform:** `fmt` + `validate` enforced in CI
- **Secrets:** Never in repo; `.env` files gitignored; CI secret scanning

---

## Documentation

- [Local Development Guide](docs/runbooks/local-dev.md)
- [CI/CD Guide](docs/runbooks/ci-cd.md)
- [Architecture Overview](docs/architecture/overview.md)
- [Security & Logging](docs/security/logging-redaction.md)

---

## License

Proprietary. All rights reserved.
