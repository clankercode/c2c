#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys

import claude_send_msg
from claude_list_sessions import find_session, load_sessions
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
    sessions = load_sessions()
    session, registration = resolve_alias(alias)
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
