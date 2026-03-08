"""Chat Worker — entry point for the background job consumer.

In production this will poll SQS for jobs. For now it serves as
the skeleton that later milestones will flesh out.
"""

import signal
import sys
import time

import structlog

from src.worker.config import get_settings

logger = structlog.get_logger(__name__)


class GracefulShutdown:
    """Handle SIGTERM/SIGINT for clean shutdown."""

    def __init__(self) -> None:
        self.should_stop = False
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum: int, frame: object) -> None:
        logger.info("shutdown_signal_received", signal=signum)
        self.should_stop = True


def run() -> None:
    """Main worker loop — poll for jobs until shutdown."""
    settings = get_settings()
    shutdown = GracefulShutdown()

    logger.info(
        "worker_started",
        env=settings.app_env,
        poll_interval=settings.poll_interval_seconds,
    )

    while not shutdown.should_stop:
        # TODO: Replace with SQS polling in M12
        time.sleep(settings.poll_interval_seconds)

    logger.info("worker_stopped")


def main() -> None:
    """Entry point."""
    try:
        run()
    except Exception:
        logger.exception("worker_fatal_error")
        sys.exit(1)


if __name__ == "__main__":
    main()
