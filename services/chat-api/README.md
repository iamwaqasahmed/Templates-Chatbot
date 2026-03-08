# Chat API Service

FastAPI service providing the chat API with SSE streaming support.

## Local Development

```bash
# Install dependencies
uv sync

# Run the server
uv run uvicorn src.app.main:app --reload --port 8000

# Run tests
uv run pytest

# Lint & format
uv run ruff check .
uv run ruff format .

# Type check
uv run mypy .
```

## API Endpoints

| Method | Path          | Description              |
|--------|---------------|--------------------------|
| GET    | `/health`     | Liveness check           |
| GET    | `/ready`      | Readiness check          |
| GET    | `/docs`       | OpenAPI Swagger UI       |

## Project Structure

```
src/app/
  main.py          # FastAPI application entry point
  api/             # Route handlers
  core/            # Config, logging, shared setup
  deps/            # Dependency injection
  models/          # Pydantic models / schemas
  services/        # Business logic
  utils/           # Helpers and utilities
```
