"""Tests for the chat worker."""

from src.worker.config import WorkerSettings, get_settings


def test_default_settings() -> None:
    """Settings should load with sensible defaults."""
    settings = WorkerSettings()
    assert settings.app_env == "local"
    assert settings.app_name == "chat-worker"
    assert settings.poll_interval_seconds > 0


def test_get_settings_returns_instance() -> None:
    """get_settings() must return a WorkerSettings instance."""
    get_settings.cache_clear()
    settings = get_settings()
    assert isinstance(settings, WorkerSettings)
