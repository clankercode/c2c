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

Today's default for both opencode and pi is ``mimo-v2.5-pro``, which both
clients expose under the same ``provider/id`` string
(``xiaomi-token-plan-sgp/mimo-v2.5-pro``) — confirm availability with
``opencode models`` and ``pi --list-models``.
"""
from __future__ import annotations

import os

# Same provider/id string works for both opencode (`opencode models`) and pi
# (`pi --list-models`), so a single shared C2C_E2E_MODEL override stays valid
# across both clients.
_MIMO_V25_PRO = "xiaomi-token-plan-sgp/mimo-v2.5-pro"

DEFAULT_MODELS: dict[str, str] = {
    "opencode": _MIMO_V25_PRO,
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
