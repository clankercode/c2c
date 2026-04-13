#!/usr/bin/env python3
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from c2c_registry import (
    default_registry_path,
    load_registry_unlocked,
    registry_path_from_env,
    registry_write_lock,
)
from c2c_whoami import current_session_identifier
from claude_list_sessions import find_session, load_sessions


ROOT = Path(__file__).resolve().parent
SWITCH = "/home/xertrov/src/call-coding-clis/ocaml"
SESSION_DISCOVERY_TIMEOUT_SECONDS = 2.0
SESSION_DISCOVERY_POLL_INTERVAL_SECONDS = 0.05


def default_broker_root() -> Path:
    return Path(default_registry_path()).parent / "mcp"


def sync_broker_registry(broker_root: Path) -> None:
    broker_root.mkdir(parents=True, exist_ok=True)
    registry_path = registry_path_from_env()
    with registry_write_lock(registry_path):
        registrations = [
            {
                "session_id": registration["session_id"],
                "alias": registration["alias"],
            }
            for registration in load_registry_unlocked(registry_path).get(
                "registrations", []
            )
        ]
        destination = broker_root / "registry.json"
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=broker_root,
            prefix=f".{destination.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            handle.write(json.dumps(registrations))
            handle.flush()
            os.fsync(handle.fileno())
            temp_path = Path(handle.name)

        os.replace(temp_path, destination)


def default_session_id() -> str:
    identifier = current_session_identifier()
    deadline = time.monotonic() + SESSION_DISCOVERY_TIMEOUT_SECONDS
    while True:
        sessions = load_sessions()
        session = find_session(identifier, sessions)
        if session is not None:
            return session["session_id"]
        if time.monotonic() >= deadline:
            raise ValueError(f"session not found: {identifier}")
        time.sleep(SESSION_DISCOVERY_POLL_INTERVAL_SECONDS)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    sync_broker_registry(broker_root)
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    if not env.get("C2C_MCP_SESSION_ID"):
        try:
            env["C2C_MCP_SESSION_ID"] = default_session_id()
        except ValueError:
            pass
    rendered_args = " ".join(shlex.quote(arg) for arg in args)
    command = (
        f'eval "$(opam env --switch={shlex.quote(SWITCH)} --set-switch)" '
        f"&& dune exec --root {shlex.quote(str(ROOT))} ./ocaml/server/c2c_mcp_server.exe -- {rendered_args}"
    ).strip()
    return subprocess.run(["bash", "-lc", command], cwd=ROOT, env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
