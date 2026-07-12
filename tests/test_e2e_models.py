from __future__ import annotations

import pytest

from tests.e2e.framework.models import DEFAULT_MODELS, e2e_model

_MIMO = "xiaomi-token-plan-sgp/mimo-v2.5-pro"

_ALL_ENV = ["C2C_E2E_MODEL", "C2C_E2E_OPENCODE_MODEL", "C2C_E2E_PI_MODEL"]


def _clear(monkeypatch: pytest.MonkeyPatch) -> None:
    for var in _ALL_ENV:
        monkeypatch.delenv(var, raising=False)


def test_defaults_are_mimo_for_opencode_and_pi(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear(monkeypatch)
    assert e2e_model("opencode") == _MIMO
    assert e2e_model("pi") == _MIMO
    assert DEFAULT_MODELS["opencode"] == _MIMO
    assert DEFAULT_MODELS["pi"] == _MIMO


def test_shared_env_overrides_default(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear(monkeypatch)
    monkeypatch.setenv("C2C_E2E_MODEL", "some/other-model")
    assert e2e_model("opencode") == "some/other-model"
    assert e2e_model("pi") == "some/other-model"


def test_per_client_env_beats_shared(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear(monkeypatch)
    monkeypatch.setenv("C2C_E2E_MODEL", "shared/model")
    monkeypatch.setenv("C2C_E2E_PI_MODEL", "pi/specific")
    assert e2e_model("pi") == "pi/specific"
    assert e2e_model("opencode") == "shared/model"


def test_unknown_client_without_env_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    _clear(monkeypatch)
    with pytest.raises(KeyError, match="no default E2E model"):
        e2e_model("nonexistent")
