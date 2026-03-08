#!/usr/bin/env bash
# =============================================================================
# bootstrap_local.sh — One-time local dev setup
# =============================================================================
set -euo pipefail

echo "==> Checking prerequisites..."

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node is required"; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "ERROR: uv is required (pip install uv)"; exit 1; }

echo "==> Installing pre-commit hooks..."
pip install pre-commit 2>/dev/null || pip3 install pre-commit
pre-commit install

echo "==> Installing Python dependencies (chat-api)..."
cd services/chat-api && uv sync && cd ../..

echo "==> Installing Python dependencies (chat-worker)..."
cd services/chat-worker && uv sync && cd ../..

echo "==> Installing Node dependencies (web)..."
cd apps/web && npm install && cd ../..

echo ""
echo "==> Local setup complete!"
echo "    Run 'make up' to start all services."
echo "    Run 'make help' to see available commands."
