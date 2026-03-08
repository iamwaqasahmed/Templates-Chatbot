# Local Development Guide

## Prerequisites

| Tool       | Version  | Install                                    |
|------------|----------|--------------------------------------------|
| Docker     | 24+      | https://docs.docker.com/get-docker/        |
| Python     | 3.11+    | https://www.python.org/downloads/          |
| uv         | latest   | `pip install uv`                           |
| Node.js    | 20 LTS   | https://nodejs.org/                        |
| Terraform  | 1.5+     | https://www.terraform.io/downloads         |
| pre-commit | latest   | `pip install pre-commit`                   |

## First-Time Setup

```bash
# Clone the repository
git clone <repo-url>
cd chatbot-platform

# Run the bootstrap script (installs hooks + dependencies)
bash infra/scripts/bootstrap_local.sh
```

Or do it manually:

```bash
# Install pre-commit hooks
pre-commit install

# Install Python deps
cd services/chat-api && uv sync && cd ../..
cd services/chat-worker && uv sync && cd ../..

# Install Node deps
cd apps/web && npm install && cd ../..
```

## Running Services

### All services (Docker Compose)

```bash
make up      # Start everything
make logs    # Tail logs
make down    # Stop and clean up
```

Services available after `make up`:

| Service       | URL                        |
|---------------|----------------------------|
| Web (Next.js) | http://localhost:3000       |
| Chat API      | http://localhost:8001       |
| API Docs      | http://localhost:8001/docs  |
| Redis         | localhost:6379              |
| DynamoDB Local| localhost:8000              |

### Individual services (for development)

```bash
# Chat API (with hot reload)
cd services/chat-api
uv run uvicorn src.app.main:app --reload --port 8000

# Web (with hot reload)
cd apps/web
npm run dev

# Worker
cd services/chat-worker
uv run python -m src.worker.main
```

## Code Quality

```bash
make lint      # Run all linters
make format    # Auto-format all code
make test      # Run all tests
```

## Environment Variables

Each service reads configuration from environment variables. For local dev,
create a `.env` file (gitignored) in the service directory:

```bash
# services/chat-api/.env
APP_ENV=local
LOG_LEVEL=DEBUG
REDIS_URL=redis://localhost:6379/0
DDB_ENDPOINT=http://localhost:8000
```

## Troubleshooting

| Problem                       | Solution                                         |
|-------------------------------|--------------------------------------------------|
| Docker build fails            | Check Docker is running; try `docker system prune`|
| Port already in use           | Check for existing processes on 3000/8001/6379    |
| Python import errors          | Run `uv sync` in the service directory            |
| Node module errors            | Run `npm install` in `apps/web`                   |
