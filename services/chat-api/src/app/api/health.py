"""Health and readiness endpoints."""

from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
async def health() -> dict[str, str]:
    """Liveness probe — returns 200 if the process is alive."""
    return {"status": "ok"}


@router.get("/ready")
async def ready() -> dict[str, str]:
    """Readiness probe — returns 200 when the service can accept traffic.

    Future: check Redis, DynamoDB connectivity before reporting ready.
    """
    # TODO: add dependency checks (Redis ping, DynamoDB describe-table, etc.)
    return {"status": "ready"}
