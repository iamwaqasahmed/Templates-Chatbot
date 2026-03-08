# =============================================================================
# Base Python image — shared across Python services
# =============================================================================
# Usage: build and tag this as a base layer if you want to share common
# system packages across chat-api and chat-worker. Optional; each service
# has its own Dockerfile that works standalone.

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# System dependencies (add shared packages here if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv
