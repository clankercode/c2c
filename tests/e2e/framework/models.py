"""Central model selection for live client E2E tests.

Live client smoke tests (opencode, pi, ...) need a real model id to launch the
inner client. This module is the single place that decision lives so an
operator can swap the model for a whole run from the shell without editing
test code.

Precedence (highest first):

  1. ``C2C_E2E_<CLIENT>_MODEL``  per-client override
     (e.g. ``C2C_E2E_PI_MODEL``, ``C2C_E2E_OPENCODE_MODEL``)
  2. ``C2C_E2E_MODEL``          applies to every client
  3. ``DEFAULT_MODELS[client]`` the checked-in default

``<CLIENT>`` is the client name upper-cased with ``-`` mapped to ``_``.

Defaults (confirm with ``opencode models`` / ``pi --list-models``):

  * opencode — ``zai-coding-plan/glm-5-turbo`` (GLM-5-Turbo)
  * pi       — ``xiaomi-token-plan-sgp/mimo-v2.5-pro``
"""
from __future__ import annotations

import os

# OpenCode: full provider/model id from `opencode models` (zai-coding-plan).
_OPENCODE_GLM_5_TURBO = "zai-coding-plan/glm-5-turbo"
# Pi default (independent provider namespace).
_MIMO_V25_PRO = "xiaomi-token-plan-sgp/mimo-v2.5-pro"

DEFAULT_MODELS: dict[str, str] = {
    "opencode": _OPENCODE_GLM_5_TURBO,
    "pi": _MIMO_V25_PRO,
}


def _env_key(client: str) -> str:
    return f"C2C_E2E_{client.upper().replace('-', '_')}_MODEL"


def e2e_model(client: str) -> str:
    """Resolve the model id to use for *client* in a live E2E test.

    Raises KeyError when no env override is set and *client* has no checked-in
    default — the caller is asking for a client this module doesn't know how to
    default for, which is a test-wiring bug worth surfacing loudly.
    """
    per_client = os.environ.get(_env_key(client))
    if per_client:
        return per_client
    shared = os.environ.get("C2C_E2E_MODEL")
    if shared:
        return shared
    try:
        return DEFAULT_MODELS[client]
    except KeyError as exc:
        raise KeyError(
            f"no default E2E model for client {client!r}; "
            f"set {_env_key(client)} or C2C_E2E_MODEL"
        ) from exc
