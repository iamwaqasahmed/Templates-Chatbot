# Chat Worker Service

Async background worker for heavy tasks (document ingestion, embeddings,
long tool calls). Consumes jobs from SQS (or a local queue in dev).

## Local Development

```bash
# Install dependencies
uv sync

# Run the worker
uv run python -m src.worker.main

# Run tests
uv run pytest

# Lint & format
uv run ruff check .
uv run ruff format .
```

## Project Structure

```
src/worker/
  main.py          # Worker entry point
  config.py        # Pydantic settings
  jobs/            # Job handlers (one per job type)
  utils/           # Helpers
```
