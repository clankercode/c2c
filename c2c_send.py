#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys

import claude_send_msg
from c2c_registry import (
    find_registration_by_alias,
    prune_registrations,
    update_registry,
)
from claude_list_sessions import load_sessions


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


def delegate_send(session: dict, message: str) -> dict:
    return claude_send_msg.send_message_to_session(session, message)


def send_to_alias(alias: str, message: str, dry_run: bool) -> dict:
    session, registration = resolve_alias(alias)
    if dry_run:
        return {
            "dry_run": True,
            "resolved_alias": registration["alias"],
            "to": session.get("name"),
            "to_session_id": session.get("session_id"),
            "message": message,
        }

    return delegate_send(session, message)


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
