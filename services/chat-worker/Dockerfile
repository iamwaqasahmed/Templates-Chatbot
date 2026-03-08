# ---- Base ----
FROM python:3.11-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# ---- Builder ----
FROM base AS builder
WORKDIR /app
RUN pip install --no-cache-dir uv
COPY pyproject.toml uv.lock* /app/
RUN uv sync --frozen --no-dev || uv sync --no-dev
COPY src/ /app/src/

# ---- Runtime ----
FROM base AS runtime
WORKDIR /app
RUN useradd --create-home --shell /bin/bash appuser
COPY --from=builder /app /app

USER appuser

CMD ["python", "-m", "src.worker.main"]
