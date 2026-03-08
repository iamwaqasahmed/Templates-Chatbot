# M1 — Repo + Engineering Standards (Monorepo + CI Skeleton) — Technical Design (v1)

M1's goal is to make the project easy to build, test, ship, and operate from day 1. When M1 is done, a new engineer can clone the repo and run one command to get a working local environment, and every PR is validated by CI with consistent quality, security, and release standards.

---

## 1. Deliverables (what exists at the end of M1)

### Source control & structure

- A **monorepo** with clear boundaries: `apps/` (frontend), `services/` (backend), `infra/` (Terraform), `docs/` (technical docs).
- Standardized tooling for **Python + Next.js + Docker + Terraform**.

### Build / test / lint standards

| Stack | Standards |
|-------|-----------|
| **Python** | Formatting, linting, type-checking, unit tests, coverage. |
| **Next.js** | Linting, formatting, unit tests (and optional e2e scaffolding). |
| **Docker** | Consistent images, multi-stage builds, non-root runtime. |
| **Secrets** | No secrets in repo; secret scanning in CI. |

### CI pipeline skeleton

- **PR checks:** lint, tests, build, security checks.
- **Main branch:** build artifacts (containers) and prepare release metadata (deployment steps come in later milestones, but wiring exists).

### Documentation baseline

- `docs/` contains: “how to run”, “how to deploy”, “how to contribute”, “coding conventions”, “architecture basics”.

---

## 2. Repository Structure (monorepo layout)

```
chatbot-platform/
  README.md
  LICENSE
  .gitignore

  docs/
    architecture/
      overview.md
      adr/
        0001-monorepo-and-tooling.md
    runbooks/
      local-dev.md
      ci-cd.md
    security/
      threat-model-v0.md
      logging-redaction.md

  apps/
    web/
      README.md
      package.json
      next.config.js
      tsconfig.json
      src/
        app/
        components/
        lib/
      tests/

  services/
    chat-api/
      README.md
      pyproject.toml
      Dockerfile
      src/
        app/
          main.py
          api/
          core/
          deps/
          models/
          services/
          utils/
      tests/

    chat-worker/
      README.md
      pyproject.toml
      Dockerfile
      src/
        worker/
          main.py
          jobs/
          utils/
      tests/

  packages/                    # optional shared code
    shared-contracts/          # types/schemas shared across services
      README.md

  infra/
    terraform/
      modules/                 # empty now (filled from M2 onward)
      live/
        dev/
        staging/
        prod/
    scripts/
      bootstrap_local.sh

  deploy/
    compose/
      docker-compose.yml
    docker/
      base-python.Dockerfile

  .github/
    workflows/
      ci.yml
      security.yml
    pull_request_template.md

  .editorconfig
  .pre-commit-config.yaml
  Makefile
```

**Principles**

- `apps/web` — frontend only.
- `services/chat-api` — API + streaming gateway + orchestration.
- `services/chat-worker` — async tasks (later: SQS).
- `infra/terraform` exists early to enforce IaC patterns even before resources land.

---

## 3. Engineering Standards (mandatory conventions)

### 3.1 Branching & release policy

**Branches**

- `main` (protected)
- `feature/*`, `fix/*`, `chore/*`
- **PR required** for main with: CI green, at least 1 approval, no direct pushes to main.

**Versioning**

- Semantic versioning for platform releases.
- Use **Conventional Commits** to automate changelog later.

**Conventional Commit examples**

- `feat(api): add SSE streaming endpoint`
- `fix(web): handle reconnect for SSE`
- `chore(ci): add pip-audit`

### 3.2 Code style & quality gates

**Python (chat-api, chat-worker)**

| Tool | Role |
|------|------|
| Formatter | Ruff format |
| Linter | Ruff |
| Type checking | mypy |
| Tests | pytest |
| Coverage | pytest-cov (min threshold enforced in CI) |

**Recommended baseline**

- Target: **Python 3.11+**
- **mypy:** “strict-ish” (start moderate, ratchet up)
- **ruff rules:** E/F/I/UP/B and security baseline

**Next.js (apps/web)**

- TypeScript required.
- **Lint:** eslint (next core rules) + typescript-eslint
- **Format:** prettier
- **Tests:** jest or vitest (choose one; scaffold now)

**Terraform**

- `terraform fmt` and `terraform validate` in CI (actual infra comes in M2).

---

## 4. Local Developer Experience (DX)

### 4.1 One-command local startup

`make up` starts:

- web
- chat-api
- chat-worker
- redis
- local db emulators (optional): dynamodb-local

### 4.2 One-command checks

- `make lint`
- `make test`
- `make format`
- `make build`

### 4.3 Docker Compose (local)

Keep local dependencies in `deploy/compose/docker-compose.yml`.

**Example skeleton:**

```yaml
services:
  redis:
    image: redis:7
    ports: ["6379:6379"]

  dynamodb:
    image: amazon/dynamodb-local
    ports: ["8000:8000"]
    command: ["-jar", "DynamoDBLocal.jar", "-inMemory", "-sharedDb"]

  chat-api:
    build:
      context: ../../services/chat-api
    environment:
      - APP_ENV=local
      - REDIS_URL=redis://redis:6379/0
      - DDB_ENDPOINT=http://dynamodb:8000
    ports: ["8001:8000"]
    depends_on: [redis, dynamodb]

  chat-worker:
    build:
      context: ../../services/chat-worker
    environment:
      - APP_ENV=local
      - REDIS_URL=redis://redis:6379/0
      - DDB_ENDPOINT=http://dynamodb:8000
    depends_on: [redis, dynamodb]

  web:
    build:
      context: ../../apps/web
    environment:
      - NEXT_PUBLIC_API_BASE_URL=http://localhost:8001
    ports: ["3000:3000"]
    depends_on: [chat-api]
```

---

## 5. Docker Standards (security + consistency)

### 5.1 Mandatory Docker rules

- Multi-stage builds
- Run as **non-root**
- Pin major versions of base images
- Minimal runtime layer
- **Healthcheck** for API service
- Build args controlled; **no secrets in image**

**Example Python service Dockerfile pattern:**

```dockerfile
FROM python:3.11-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

FROM base AS builder
WORKDIR /app
RUN pip install --no-cache-dir uv
COPY pyproject.toml uv.lock* /app/
RUN uv sync --frozen

COPY src/ /app/src/

FROM base AS runtime
WORKDIR /app
RUN useradd -m appuser
COPY --from=builder /app /app
USER appuser
EXPOSE 8000
CMD ["python", "-m", "src.app.main"]
```

**Next.js Dockerfile pattern (SSR-capable, still safe):**

```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app ./
EXPOSE 3000
CMD ["npm", "run", "start"]
```

---

## 6. Configuration & Secrets (how config works)

### 6.1 Environment strategy

- **APP_ENV:** `local` | `dev` | `staging` | `prod`
- **Config precedence:** environment variables → local `.env` (local only, gitignored) → defaults in code

### 6.2 No secrets in repo

- `.env` files are gitignored.
- CI runs secret scanning (see below).
- In AWS later: Secrets Manager + task role access (M1 sets the pattern).

### 6.3 Typed settings in Python

- Use **Pydantic settings** in each service.
- Settings class with strict types; **validate at startup and fail fast**.

---

## 7. Baseline Logging Standard (important for later SLOs)

Even in M1, enforce:

- **JSON structured logs**
- **Fields:** timestamp, level, service, request_id, tenant_id, user_id_hash, conversation_id, event, latency_ms
- **PII policy:** never log raw message content by default

---

## 8. GitHub: PR templates + Issue hygiene

### 8.1 PR template (`.github/pull_request_template.md`)

- Summary
- Test plan
- Risk/rollout notes
- Screenshots (web)
- Checklist (lint/test, docs updated)

### 8.2 CODEOWNERS (optional)

- Enforce reviews on infra or security changes.

---

## 9. Pre-commit Hooks (fast feedback locally)

**Example `.pre-commit-config.yaml` skeleton:**

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.9
    hooks:
      - id: ruff
      - id: ruff-format

  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.92.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
```

---

## 10. CI Pipeline (PR checks) — what runs and why

### 10.1 CI goals

- Catch issues before merge
- Ensure builds are reproducible
- Provide security baseline

### 10.2 Required CI checks (PR)

| Area | Checks |
|------|--------|
| **Python** | ruff lint + format check, mypy, pytest + coverage |
| **Web** | eslint, typecheck, tests |
| **Docker** | Build images (at least “build succeeds”) |
| **Terraform** | fmt + validate |
| **Security** | Secret scanning, dependency audit |

### 10.3 Example GitHub Actions (`.github/workflows/ci.yml`)

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]

jobs:
  python:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [services/chat-api, services/chat-worker]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install
        run: |
          cd ${{ matrix.service }}
          pip install uv
          uv sync --frozen
      - name: Lint + Format
        run: |
          cd ${{ matrix.service }}
          uv run ruff check .
          uv run ruff format --check .
      - name: Typecheck
        run: |
          cd ${{ matrix.service }}
          uv run mypy .
      - name: Tests
        run: |
          cd ${{ matrix.service }}
          uv run pytest -q --disable-warnings --maxfail=1 --cov=src --cov-fail-under=80

  web:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/web
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: apps/web/package-lock.json
      - run: npm ci
      - run: npm run lint
      - run: npm run typecheck
      - run: npm test --if-present
      - run: npm run build

  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform fmt -check -recursive infra/terraform
      - run: |
          cd infra/terraform
          terraform validate

  docker-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build images
        run: |
          docker build -t chat-api:ci services/chat-api
          docker build -t chat-worker:ci services/chat-worker
          docker build -t web:ci apps/web
```

---

## 11. Security Baseline in CI (M1-level)

Add a **separate workflow** (`security.yml`) to keep CI fast.

**Minimum:**

- **Secret scanning** (e.g., gitleaks)
- **Python dependency audit** (pip-audit)
- **Node audit** (`npm audit --omit=dev` or osv-scanner)
- **Container scan** (Trivy) — can be “warning only” initially, then enforce later

---

## 12. Makefile (single entry point)

**Example Makefile targets:**

```makefile
.PHONY: up down logs lint test format build

up:
	cd deploy/compose && docker compose up -d --build

down:
	cd deploy/compose && docker compose down -v

logs:
	cd deploy/compose && docker compose logs -f --tail=200

lint:
	cd services/chat-api && uv run ruff check .
	cd services/chat-worker && uv run ruff check .
	cd apps/web && npm run lint

format:
	cd services/chat-api && uv run ruff format .
	cd services/chat-worker && uv run ruff format .
	cd apps/web && npm run format

test:
	cd services/chat-api && uv run pytest
	cd services/chat-worker && uv run pytest
	cd apps/web && npm test --if-present

build:
	docker build -t chat-api:local services/chat-api
	docker build -t chat-worker:local services/chat-worker
	docker build -t web:local apps/web
```

---

## 13. Definition of Done (M1 acceptance checklist)

M1 is **done** when:

- [ ] `make up` brings up web + api + worker + redis (and optional dynamodb-local)
- [ ] `make lint`, `make test`, `make build` all pass locally
- [ ] PR CI runs and passes on a clean branch
- [ ] Pre-commit hooks run successfully
- [ ] Docker images run non-root and build reproducibly
- [ ] Docs exist:
  - `docs/runbooks/local-dev.md`
  - `docs/runbooks/ci-cd.md`
  - `docs/architecture/overview.md`
- [ ] No secrets in repo; secret scanning workflow enabled

---

*Next: generate the exact initial repo files for M1 (config files + minimal FastAPI/Next.js entrypoints + compose + CI YAMLs), then proceed to M2 (Terraform foundation + remote state + env isolation).*
