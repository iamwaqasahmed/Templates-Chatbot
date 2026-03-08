"""Application configuration — Pydantic settings with strict types."""

from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Central configuration loaded from environment variables.

    In local dev, values come from a `.env` file (gitignored).
    In AWS, they come from ECS task environment / Secrets Manager.
    """

    # General
    app_env: str = "local"  # local | dev | staging | prod
    app_name: str = "chat-api"
    log_level: str = "INFO"
    debug: bool = False

    # Server
    host: str = "0.0.0.0"  # noqa: S104 — intentional for container binding
    port: int = 8000

    # CORS
    cors_origins: list[str] = ["http://localhost:3000"]

    # Redis (future milestones)
    redis_url: str = "redis://localhost:6379/0"

    # DynamoDB (future milestones)
    ddb_endpoint: str | None = None  # set for dynamodb-local
    ddb_region: str = "us-east-1"

    model_config = {
        "env_prefix": "",
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return cached settings singleton."""
    return Settings()
