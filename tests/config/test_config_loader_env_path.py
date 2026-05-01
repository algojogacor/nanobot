from pathlib import Path

from nanobot.config.loader import get_config_path, set_config_path


def test_get_config_path_uses_env_override(monkeypatch, tmp_path):
    set_config_path(None)  # type: ignore[arg-type]
    custom = tmp_path / "custom-config.json"
    monkeypatch.setenv("NANOBOT_CONFIG_PATH", str(custom))

    assert get_config_path() == custom


def test_get_config_path_prefers_explicit_setter(monkeypatch, tmp_path):
    env_path = tmp_path / "env-config.json"
    explicit = tmp_path / "explicit-config.json"
    monkeypatch.setenv("NANOBOT_CONFIG_PATH", str(env_path))
    set_config_path(explicit)

    try:
        assert get_config_path() == explicit
    finally:
        set_config_path(None)  # type: ignore[arg-type]
