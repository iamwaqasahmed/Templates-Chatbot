.PHONY: up down logs lint format test build clean help

# ---------------------------------------------------------------------------
# Local environment
# ---------------------------------------------------------------------------

up: ## Start all services (web + api + worker + redis + dynamodb-local)
	cd deploy/compose && docker compose up -d --build

down: ## Stop all services and remove volumes
	cd deploy/compose && docker compose down -v

logs: ## Tail service logs
	cd deploy/compose && docker compose logs -f --tail=200

# ---------------------------------------------------------------------------
# Code quality
# ---------------------------------------------------------------------------

lint: ## Run linters across all stacks
	cd services/chat-api && uv run ruff check .
	cd services/chat-worker && uv run ruff check .
	cd apps/web && npm run lint

format: ## Auto-format all code
	cd services/chat-api && uv run ruff format .
	cd services/chat-worker && uv run ruff format .
	cd apps/web && npm run format

test: ## Run all tests
	cd services/chat-api && uv run pytest -q --disable-warnings
	cd services/chat-worker && uv run pytest -q --disable-warnings
	cd apps/web && npm test -- --run

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build: ## Build all Docker images
	docker build -t chat-api:local services/chat-api
	docker build -t chat-worker:local services/chat-worker
	docker build -t web:local apps/web

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

clean: ## Remove caches and build artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name node_modules -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .next -exec rm -rf {} + 2>/dev/null || true

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
