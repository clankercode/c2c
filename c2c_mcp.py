#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from c2c_registry import (
    build_registration_record,
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
SESSION_DISCOVERY_TIMEOUT_SECONDS = 10.0
SESSION_DISCOVERY_POLL_INTERVAL_SECONDS = 0.1


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
        existing_by_session_id = {
            registration["session_id"]: registration
            for registration in load_broker_registrations(destination)
        }
        registrations = [
            merge_broker_registration(
                existing_by_session_id.get(registration["session_id"]), registration
            )
            for registration in load_registry_unlocked(registry_path).get(
                "registrations", []
            )
        ]
        known_session_ids = {
            registration["session_id"] for registration in registrations
        }
        known_aliases = {registration["alias"] for registration in registrations}
        for registration in existing_by_session_id.values():
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


def merge_broker_registration(
    existing: dict[str, object] | None, registration: dict
) -> dict:
    merged = dict(existing or {})
    merged["session_id"] = registration["session_id"]
    merged["alias"] = registration["alias"]
    for field in ("pid", "pid_start_time"):
        if field in registration:
            merged[field] = registration[field]
    return merged


def auto_register_alias_from_env(env: dict[str, str] | None = None) -> str | None:
    source = os.environ if env is None else env
    alias = str(source.get("C2C_MCP_AUTO_REGISTER_ALIAS", "")).strip()
    return alias or None


def current_client_pid_from_env(env: dict[str, str]) -> int | None:
    value = str(env.get("C2C_MCP_CLIENT_PID", "")).strip()
    if value:
        try:
            return int(value)
        except ValueError:
            return None
    return os.getppid()


def read_pid_start_time(pid: int) -> int | None:
    try:
        line = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except OSError:
        return None
    tail_start = line.rfind(")")
    if tail_start == -1 or tail_start + 2 >= len(line):
        return None
    parts = line[tail_start + 2 :].split()
    if len(parts) <= 19:
        return None
    try:
        return int(parts[19])
    except ValueError:
        return None


def proc_cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def is_opencode_run_pid(pid: object) -> bool:
    if not isinstance(pid, int):
        return False
    parts = proc_cmdline(pid).split()
    has_opencode = any(Path(part).name in {"opencode", ".opencode"} for part in parts)
    return has_opencode and "run" in parts


def broker_registration_is_alive(registration: dict[str, object]) -> bool:
    pid = registration.get("pid")
    if not isinstance(pid, int):
        return False
    if not os.path.exists(f"/proc/{pid}"):
        return False
    stored_start_time = registration.get("pid_start_time")
    if not isinstance(stored_start_time, int):
        return True
    return read_pid_start_time(pid) == stored_start_time


def _session_pid_from_proc(session_id: str) -> int | None:
    """Scan /proc for a live process whose session matches session_id."""
    try:
        from claude_list_sessions import iter_live_claude_processes

        for pid, sid, _cwd in iter_live_claude_processes():
            if sid == session_id:
                return pid
    except Exception:
        pass
    return None


def maybe_auto_register_startup(env: dict[str, str]) -> None:
    alias = auto_register_alias_from_env(env)
    session_id = str(env.get("C2C_MCP_SESSION_ID", "")).strip()
    if not alias or not session_id:
        return

    broker_root = Path(env.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    broker_root.mkdir(parents=True, exist_ok=True)
    registry_path = broker_root / "registry.json"
    # Prefer /proc-discovered pid over the inherited C2C_MCP_CLIENT_PID env var,
    # which can be stale after a session restart (the env var captures the pid at
    # MCP server first-launch time and doesn't update on subsequent restarts).
    pid = _session_pid_from_proc(session_id) or current_client_pid_from_env(env)
    pid_start_time = read_pid_start_time(pid) if pid is not None else None
    registration = build_registration_record(
        session_id,
        alias,
        pid=pid,
        pid_start_time=pid_start_time,
    )

    with registry_write_lock(registry_path):
        registrations = load_broker_registrations(registry_path)
        for existing in registrations:
            if (
                existing.get("session_id") == session_id
                and existing.get("alias") == alias
                and broker_registration_is_alive(existing)
                and not (
                    is_opencode_run_pid(existing.get("pid"))
                    and not is_opencode_run_pid(pid)
                )
            ):
                return
        registrations = [
            existing
            for existing in registrations
            if existing.get("session_id") != session_id
            and existing.get("alias") != alias
        ]
        registrations.insert(0, registration)

        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=broker_root,
            prefix=f".{registry_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            handle.write(json.dumps(registrations))
            handle.flush()
            os.fsync(handle.fileno())
            temp_path = Path(handle.name)

        os.replace(temp_path, registry_path)


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
    if not env.get("C2C_MCP_CLIENT_PID"):
        env["C2C_MCP_CLIENT_PID"] = str(os.getppid())
    if not env.get("C2C_MCP_SESSION_ID"):
        try:
            env["C2C_MCP_SESSION_ID"] = default_session_id()
        except ValueError as discovery_error:
            # Critical for poll_inbox / register / send_room to work without
            # an explicit session_id argument. Surface it loudly on stderr so
            # operators notice instead of seeing silent "missing session_id"
            # errors on every tool call for the rest of the session.
            print(
                f"c2c_mcp: WARNING session discovery failed ({discovery_error}); "
                "tool calls will need an explicit session_id argument until the "
                "MCP server is restarted in a context where /proc scanning can "
                f"find the parent session (timeout was {SESSION_DISCOVERY_TIMEOUT_SECONDS}s)",
                file=sys.stderr,
                flush=True,
            )
    maybe_auto_register_startup(env)
    build_server(env)
    return subprocess.run(
        [str(built_server_path()), *args], cwd=ROOT, env=env
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
