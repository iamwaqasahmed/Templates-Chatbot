# CI/CD Guide

## Pipeline Overview

We use **GitHub Actions** with two workflows:

### 1. CI Workflow (`.github/workflows/ci.yml`)

Runs on every PR and push to `main`.

| Job            | What it does                                    |
|----------------|-------------------------------------------------|
| `python`       | Ruff lint + format check, mypy, pytest (matrix) |
| `web`          | ESLint, typecheck, vitest, Next.js build         |
| `terraform`    | `terraform fmt` + `terraform validate`           |
| `docker-build` | Build all Docker images (build-only, no push)    |

### 2. Security Workflow (`.github/workflows/security.yml`)

Runs on PRs, pushes to `main`, and weekly (cron).

| Job              | What it does                            |
|------------------|-----------------------------------------|
| `gitleaks`       | Scan for secrets in git history         |
| `python-audit`   | pip-audit on Python dependencies        |
| `node-audit`     | npm audit on Node dependencies          |
| `container-scan` | Trivy scan on built Docker images       |

## Branch Strategy

- **`main`** — Protected; requires CI green + 1 approval.
- **`feature/*`** — New features.
- **`fix/*`** — Bug fixes.
- **`chore/*`** — Tooling, CI, dependency updates.

## Commit Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(api): add SSE streaming endpoint
fix(web): handle reconnect for SSE
chore(ci): add pip-audit step
docs(runbooks): update local-dev guide
```

## Adding a New Service to CI

1. Create the service under `services/<name>/` with the standard structure.
2. Add it to the `matrix.service` list in `ci.yml`.
3. Add a Docker build step in `ci.yml` → `docker-build` job.
4. Add dependency auditing in `security.yml`.

## Future Enhancements (Later Milestones)

- Container image push to ECR on `main` merge.
- Blue/green deployments via CodeDeploy + ECS.
- Environment promotion (dev → staging → prod).
- Release tagging and changelog generation.
