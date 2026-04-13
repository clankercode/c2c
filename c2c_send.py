#!/usr/bin/env python3
import argparse
import contextlib
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import claude_send_msg
from claude_list_sessions import find_session, load_sessions
from c2c_mcp import default_broker_root, load_broker_registrations
from c2c_registry import load_registration_for_session_id
from c2c_registry import (
    find_registration_by_alias,
    prune_registrations,
    update_registry,
)


BROKER_INBOX_THREAD_LOCKS: dict[str, threading.Lock] = {}
BROKER_INBOX_THREAD_LOCKS_GUARD = threading.Lock()


def resolve_alias(alias: str) -> tuple[dict, dict]:
    sessions = load_sessions()
    sessions_by_id = {session.get("session_id"): session for session in sessions}

    def mutate_registry(registry: dict) -> dict | None:
        pruned_registry = prune_registrations(registry, set(sessions_by_id))
        registry["registrations"] = pruned_registry["registrations"]
        return find_registration_by_alias(registry, alias)

    registration = update_registry(mutate_registry)
    if registration is None:
        raise ValueError(f"unknown alias: {alias}")

    session = sessions_by_id.get(registration["session_id"])
    if session is None:
        raise ValueError(f"unknown alias: {alias}")
    return session, registration


def resolve_broker_only_alias(alias: str) -> dict | None:
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    registrations = load_broker_registrations(broker_root / "registry.json")
    for registration in registrations:
        if registration.get("alias") == alias and broker_registration_is_alive(
            registration
        ):
            return registration
    return None


def broker_alias_exists(alias: str) -> bool:
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    registrations = load_broker_registrations(broker_root / "registry.json")
    return any(registration.get("alias") == alias for registration in registrations)


def enqueue_broker_message(session_id: str, to_alias: str, message: str) -> dict:
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    broker_root.mkdir(parents=True, exist_ok=True)
    inbox_path = broker_root / f"{session_id}.inbox.json"
    sender = resolve_sender_metadata()
    with broker_inbox_write_lock(inbox_path):
        try:
            items = json.loads(inbox_path.read_text(encoding="utf-8"))
            if not isinstance(items, list):
                items = []
        except Exception:
            items = []
        items.append(
            {
                "from_alias": resolve_sender_broker_alias() or sender["name"],
                "to_alias": to_alias,
                "content": message,
            }
        )
        write_broker_inbox(inbox_path, items)
    return {
        "ok": True,
        "to": f"broker:{session_id}",
        "session_id": session_id,
        "sent_at": None,
    }


def delegate_send(session: dict, message: str, sessions: list[dict]) -> dict:
    sender = resolve_sender_metadata(sessions)
    return claude_send_msg.send_message_to_session(
        session,
        message,
        event="message",
        sender_name=sender["name"],
        sender_alias=sender["alias"],
        sessions=sessions,
    )


def resolve_sender_metadata(sessions: list[dict] | None = None) -> dict:
    if sessions is None:
        sessions = load_sessions()

    session_id = os.environ.get("C2C_SESSION_ID", "").strip()
    if session_id:
        registration = load_registration_for_session_id(session_id)
        if registration is not None:
            session = find_session(session_id, sessions)
            if session is not None:
                return {
                    "name": session.get("name") or registration["alias"],
                    "alias": "",
                }

    session_pid = os.environ.get("C2C_SESSION_PID", "").strip()
    if session_pid:
        session = find_session(session_pid, sessions)
        if session is not None:
            registration = load_registration_for_session_id(session["session_id"])
            if registration is not None:
                return {
                    "name": session.get("name") or registration["alias"],
                    "alias": "",
                }

    return {"name": "c2c-send", "alias": ""}


def resolve_sender_broker_alias(sessions: list[dict] | None = None) -> str:
    if sessions is None:
        sessions = load_sessions()

    session_id = os.environ.get("C2C_SESSION_ID", "").strip()
    if session_id:
        registration = load_registration_for_session_id(session_id)
        if registration is not None and find_session(session_id, sessions) is not None:
            return str(registration.get("alias", "")).strip()

    session_pid = os.environ.get("C2C_SESSION_PID", "").strip()
    if session_pid:
        session = find_session(session_pid, sessions)
        if session is not None:
            registration = load_registration_for_session_id(session["session_id"])
            if registration is not None:
                return str(registration.get("alias", "")).strip()

    return ""


@contextlib.contextmanager
def broker_inbox_write_lock(inbox_path: Path):
    thread_lock = broker_inbox_thread_lock(inbox_path)
    lock_path = broker_inbox_lock_path(inbox_path)
    with thread_lock:
        with open(lock_path, "w", encoding="utf-8") as handle:
            fcntl.lockf(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.lockf(handle, fcntl.LOCK_UN)


def broker_inbox_lock_path(inbox_path: Path) -> Path:
    name = inbox_path.name
    suffix = ".inbox.json"
    if name.endswith(suffix):
        return inbox_path.with_name(name[: -len(suffix)] + ".inbox.lock")
    return inbox_path.with_suffix(f"{inbox_path.suffix}.lock")


def broker_inbox_thread_lock(inbox_path: Path) -> threading.Lock:
    key = str(inbox_path)
    with BROKER_INBOX_THREAD_LOCKS_GUARD:
        lock = BROKER_INBOX_THREAD_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            BROKER_INBOX_THREAD_LOCKS[key] = lock
        return lock


def write_broker_inbox(inbox_path: Path, items: list[dict]) -> None:
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=inbox_path.parent,
        prefix=f".{inbox_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write(json.dumps(items))
        handle.flush()
        os.fsync(handle.fileno())
        temp_path = Path(handle.name)

    os.replace(temp_path, inbox_path)


def broker_registration_is_alive(registration: dict) -> bool:
    pid = registration.get("pid")
    if not isinstance(pid, int):
        return True
    if not os.path.exists(f"/proc/{pid}"):
        return False
    stored_start_time = registration.get("pid_start_time")
    if not isinstance(stored_start_time, int):
        return True
    return read_pid_start_time(pid) == stored_start_time


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


def send_to_alias(alias: str, message: str, dry_run: bool) -> dict:
    try:
        sessions = load_sessions()
        session, registration = resolve_alias(alias)
    except ValueError:
        registration = resolve_broker_only_alias(alias)
        if registration is None:
            if broker_alias_exists(alias):
                raise ValueError(f"recipient is not alive: {alias}")
            raise ValueError(f"unknown alias: {alias}")
        if dry_run:
            return {
                "dry_run": True,
                "resolved_alias": registration["alias"],
                "to": f"broker:{registration['session_id']}",
                "to_session_id": registration["session_id"],
                "message": message,
            }
        return enqueue_broker_message(registration["session_id"], alias, message)

    if dry_run:
        return {
            "dry_run": True,
            "resolved_alias": registration["alias"],
            "to": session.get("name"),
            "to_session_id": session.get("session_id"),
            "message": message,
        }

    return delegate_send(session, message, sessions)


def describe_send_failure(error: Exception) -> str:
    if isinstance(error, subprocess.CalledProcessError):
        detail = (error.stderr or error.stdout or "").strip()
        if detail:
            return f"send failed: {detail}"
        return "send failed"
    return str(error)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Send a c2c message to an opted-in alias."
    )
    parser.add_argument("alias")
    parser.add_argument("message", nargs="+")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        result = send_to_alias(args.alias, " ".join(args.message), args.dry_run)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(describe_send_failure(error), file=sys.stderr)
        return 1

    if args.json or args.dry_run:
        print(json.dumps(result, indent=2))
        return 0

    print(f"Sent c2c message to {result['to']} ({args.alias})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
