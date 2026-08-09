"""Identity — auto-register a c2c alias on session start.

Called from the on_session_start hook. Pins the session id and client type in
the process environment FIRST, then checks `c2c whoami` and registers if
needed.

Ordering matters: c2c resolves a session's identity from C2C_MCP_SESSION_ID,
falling back to the host client's own env markers. A Hermes launched from
inside another agent's shell inherits that parent's session id (the same
footgun c2c's CLAUDE.md documents for `kimi -p` inside Claude Code), so the
first `whoami` would adopt — and the first `register` would rename — the
PARENT's registration. Setting the env var before any c2c call is the only
lever: `c2c register` does accept `--session-id`, but `whoami` does not, and
every later tool/command call needs the same identity anyway.
"""

import os
import logging
import hashlib
import time

logger = logging.getLogger("c2c.identity")

# Module-level state — the current alias, set after registration.
_current_alias = None
_current_session_id = None

# c2c session ids and aliases must match [A-Za-z0-9._-]{1,64} and must not
# start with '.' (ocaml/c2c_name.ml). Anything else is rejected outright.
_SAFE_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789._-"
)


def get_alias():
    """Return the current c2c alias (or None if not registered)."""
    return _current_alias


def get_session_id():
    """Return the current c2c session id (or None)."""
    return _current_session_id


def _sanitize(raw, fallback):
    """Coerce `raw` into a name c2c will accept, else return `fallback`."""
    if not raw:
        return fallback
    cleaned = "".join(c if c in _SAFE_CHARS else "-" for c in str(raw))
    cleaned = cleaned.strip("-")[:64]
    if not cleaned or cleaned[0] == ".":
        return fallback
    return cleaned


def _generate_alias(session_id):
    """Generate a deterministic hermes-<hash> alias from the session id."""
    base = session_id or str(time.time())
    h = hashlib.sha256(base.encode()).hexdigest()[:8]
    return f"hermes-{h}"


def _resolve_session_id(payload_session_id):
    """Decide which session id this Hermes process owns.

    Priority:
      1. the id Hermes handed us in the on_session_start payload;
      2. an existing C2C_MCP_SESSION_ID that is already ours (`hermes-*`) —
         e.g. exported by a future managed launcher;
      3. a process-local id derived from pid + boot time.

    An inherited, non-hermes C2C_MCP_SESSION_ID is deliberately NOT trusted:
    it belongs to whichever agent spawned us.
    """
    if payload_session_id:
        return _sanitize(payload_session_id, _generate_alias(payload_session_id))
    inherited = os.environ.get("C2C_MCP_SESSION_ID", "")
    if inherited.startswith("hermes-"):
        return inherited
    seed = f"{os.getpid()}:{time.time()}"
    return "hermes-" + hashlib.sha256(seed.encode()).hexdigest()[:16]


def register_identity(session_id=None, model=None, platform=None, **kwargs):
    """on_session_start hook: auto-register c2c identity.

    Accepts **kwargs for forward compatibility — the hook may receive
    additional parameters in future Hermes versions.
    """
    global _current_alias, _current_session_id

    # Pin client type so c2c doesn't misidentify us (E9), and pin the session
    # id BEFORE the first c2c call so we cannot adopt a parent agent's row.
    os.environ["C2C_MCP_CLIENT_TYPE"] = "hermes"
    resolved_sid = _resolve_session_id(session_id)
    os.environ["C2C_MCP_SESSION_ID"] = resolved_sid
    _current_session_id = resolved_sid

    from .c2c_cli import C2cCli

    cli = C2cCli()
    if not cli.available:
        logger.warning("[c2c] binary not found — skipping identity registration. "
                        "Set C2C_BIN or install c2c.")
        return

    # Check if already registered.
    try:
        who = cli.whoami()
        if isinstance(who, dict) and who.get("alias") and "error" not in who:
            _current_alias = who["alias"]
            _current_session_id = who.get("session_id") or resolved_sid
            logger.info("[c2c] already registered as %s (session %s)",
                        _current_alias, _current_session_id)
            _auto_join_rooms(cli)
            return
    except Exception as e:
        logger.debug("[c2c] whoami check failed: %s", e)

    # Not registered — register now. The alias is passed through the env, NOT
    # through `--alias`: a `hermes-` prefixed name is a reserved client prefix
    # and `--alias` is the user-supplied path, which the blocklist refuses.
    #
    # ..._FROM_AUTO_GEN=1 asserts "c2c's own generator produced this name" and
    # is what lets a reserved `hermes-` prefix through. Setting it for an
    # OPERATOR-supplied alias would launder that operator's name past the very
    # blocklist check `hermes-` was just added to, so it is set only for names
    # this plugin generated itself.
    operator_alias = _sanitize(os.environ.get("C2C_MCP_AUTO_REGISTER_ALIAS"), "")
    if operator_alias:
        alias = operator_alias
        # Deliberately not cleared: an operator who exported FROM_AUTO_GEN
        # themselves has made that claim explicitly. We just never make it
        # on their behalf.
    else:
        alias = _generate_alias(resolved_sid)
        os.environ["C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN"] = "1"
    os.environ["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias

    try:
        result = cli.register()
        if isinstance(result, dict) and result.get("alias"):
            _current_alias = result["alias"]
            _current_session_id = result.get("session_id") or resolved_sid
        elif isinstance(result, dict) and result.get("error"):
            logger.warning("[c2c] registration failed: %s", result.get("error"))
            # Try whoami in case we were already registered and the error is a duplicate.
            try:
                who = cli.whoami()
                if isinstance(who, dict) and who.get("alias"):
                    _current_alias = who["alias"]
                    _current_session_id = who.get("session_id") or resolved_sid
            except Exception:
                pass
        else:
            _current_alias = alias
        logger.info("[c2c] registered as %s (session %s)", _current_alias, _current_session_id)
        _auto_join_rooms(cli)
    except Exception as e:
        logger.warning("[c2c] registration error: %s", e)


def _auto_join_rooms(cli):
    """Auto-join default rooms from C2C_MCP_AUTO_JOIN_ROOMS env var."""
    rooms_env = os.environ.get("C2C_MCP_AUTO_JOIN_ROOMS", "swarm-lounge")
    rooms = [r.strip() for r in rooms_env.split(",") if r.strip()]
    for room in rooms:
        try:
            cli.rooms_join(room)
            logger.info("[c2c] auto-joined room: %s", room)
        except Exception as e:
            logger.debug("[c2c] auto-join %s failed: %s", room, e)
