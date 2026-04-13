#!/usr/bin/env python3
import json
import os
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
SERVER_BUILD_TARGET = "./ocaml/server/c2c_mcp_server.exe"
SESSION_DISCOVERY_TIMEOUT_SECONDS = 2.0
SESSION_DISCOVERY_POLL_INTERVAL_SECONDS = 0.05


def default_broker_root() -> Path:
    return Path(default_registry_path()).parent / "mcp"


def load_broker_registrations(path: Path) -> list[dict[str, object]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    registrations = []
    for item in data:
        if not isinstance(item, dict):
            continue
        session_id = str(item.get("session_id", "")).strip()
        alias = str(item.get("alias", "")).strip()
        if session_id and alias:
            registration = dict(item)
            registration["session_id"] = session_id
            registration["alias"] = alias
            registrations.append(registration)
    return registrations


def sync_broker_registry(broker_root: Path) -> None:
    broker_root.mkdir(parents=True, exist_ok=True)
    registry_path = registry_path_from_env()
    with registry_write_lock(registry_path):
        destination = broker_root / "registry.json"
        registrations = [
            {
                "session_id": registration["session_id"],
                "alias": registration["alias"],
            }
            for registration in load_registry_unlocked(registry_path).get(
                "registrations", []
            )
        ]
        known_session_ids = {
            registration["session_id"] for registration in registrations
        }
        known_aliases = {registration["alias"] for registration in registrations}
        for registration in load_broker_registrations(destination):
            if registration["session_id"] in known_session_ids:
                continue
            if registration["alias"] in known_aliases:
                continue
            registrations.append(registration)

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


def built_server_path() -> Path:
    return ROOT / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"


def build_server(env: dict[str, str]) -> None:
    subprocess.run(
        [
            "opam",
            "exec",
            f"--switch={SWITCH}",
            "--",
            "dune",
            "build",
            "--root",
            str(ROOT),
            SERVER_BUILD_TARGET,
        ],
        cwd=ROOT,
        env=env,
        check=True,
    )


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    sync_broker_registry(broker_root)
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_CLIENT_PID"] = str(os.getpid())
    if not env.get("C2C_MCP_SESSION_ID"):
        try:
            env["C2C_MCP_SESSION_ID"] = default_session_id()
        except ValueError:
            pass
    build_server(env)
    return subprocess.run(
        [str(built_server_path()), *args], cwd=ROOT, env=env
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
