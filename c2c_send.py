#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
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
        if registration.get("alias") == alias:
            return registration
    return None


def enqueue_broker_message(session_id: str, to_alias: str, message: str) -> dict:
    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    broker_root.mkdir(parents=True, exist_ok=True)
    inbox_path = broker_root / f"{session_id}.inbox.json"
    try:
        items = json.loads(inbox_path.read_text(encoding="utf-8"))
        if not isinstance(items, list):
            items = []
    except Exception:
        items = []
    sender = resolve_sender_metadata([])
    items.append(
        {
            "from_alias": sender["name"],
            "to_alias": to_alias,
            "content": message,
        }
    )
    inbox_path.write_text(json.dumps(items), encoding="utf-8")
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


def send_to_alias(alias: str, message: str, dry_run: bool) -> dict:
    try:
        sessions = load_sessions()
        session, registration = resolve_alias(alias)
    except ValueError:
        registration = resolve_broker_only_alias(alias)
        if registration is None:
            raise
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
