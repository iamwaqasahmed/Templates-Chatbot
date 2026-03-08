"""Worker configuration — Pydantic settings."""

from functools import lru_cache

from pydantic_settings import BaseSettings


class WorkerSettings(BaseSettings):
    """Configuration for the background worker."""

    app_env: str = "local"
    app_name: str = "chat-worker"
    log_level: str = "INFO"

    # Polling
    poll_interval_seconds: float = 5.0

    # Redis (future milestones)
    redis_url: str = "redis://localhost:6379/0"

    # DynamoDB (future milestones)
    ddb_endpoint: str | None = None
    ddb_region: str = "us-east-1"

    # SQS (future milestones)
    sqs_queue_url: str | None = None

    model_config = {
        "env_prefix": "",
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


@lru_cache(maxsize=1)
def get_settings() -> WorkerSettings:
    """Return cached settings singleton."""
    return WorkerSettings()
