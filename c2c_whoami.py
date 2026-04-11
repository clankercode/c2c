#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path

from c2c_registry import load_registration_for_session_id
from claude_list_sessions import find_session, load_sessions, parent_pid


TUTORIAL_LINES = [
    "What is C2C?",
    "C2C lets opted-in Claude sessions message each other by alias.",
    "Use c2c-send <alias> <message...>",
]


def tutorial_text() -> str:
    return "\n".join(TUTORIAL_LINES)


def child_processes(pid: int | None) -> list[tuple[int, str]]:
    if not isinstance(pid, int):
        return []
    children_path = Path(f"/proc/{pid}/task/{pid}/children")
    try:
        child_pids = [int(value) for value in children_path.read_text().split()]
    except Exception:
        return []

    children = []
    for child_pid in child_pids:
        comm_path = Path(f"/proc/{child_pid}/comm")
        try:
            name = comm_path.read_text().strip()
        except Exception:
            continue
        children.append((child_pid, name))
    return children


def parent_process_chain(start_pid: int) -> list[int]:
    chain = []
    current_pid = start_pid
    seen = set()

    while isinstance(current_pid, int) and current_pid > 0 and current_pid not in seen:
        chain.append(current_pid)
        seen.add(current_pid)
        current_pid = parent_pid(current_pid)

    return chain


def infer_current_session_pid() -> str:
    for pid in parent_process_chain(os.getpid()):
        claude_children = [
            child_pid for child_pid, name in child_processes(pid) if name == "claude"
        ]
        if len(claude_children) == 1:
            return str(claude_children[0])
        if len(claude_children) > 1:
            break
    raise ValueError(
        "could not resolve current session uniquely; use a session ID or PID"
    )


def current_session_identifier() -> str:
    session_pid = os.environ.get("C2C_SESSION_PID", "").strip()
    if session_pid:
        return session_pid
    session_id = os.environ.get("C2C_SESSION_ID", "").strip()
    if session_id:
        return session_id
    return infer_current_session_pid()


def resolve_identity(identifier: str | None) -> tuple[dict, dict | None]:
    sessions = load_sessions()
    if identifier is None:
        identifier = current_session_identifier()
    session = find_session(identifier, sessions)
    if session is None:
        raise ValueError(f"session not found: {identifier}")
    registration = load_registration_for_session_id(session["session_id"])
    if registration is None:
        raise ValueError(f"session is not registered: {session['session_id']}")
    return session, registration


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Show c2c identity details for the current or selected session."
    )
    parser.add_argument("session", nargs="?")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        session, registration = resolve_identity(args.session)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

    payload = {
        "name": session.get("name", ""),
        "session_id": session["session_id"],
        "alias": registration["alias"],
        "registered": True,
        "tutorial": tutorial_text(),
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"Alias: {payload['alias'] or '<unregistered>'}")
    print(f"Session: {payload['name']}")
    print(f"Session ID: {payload['session_id']}")
    print(f"Registered: {'yes' if payload['registered'] else 'no'}")
    print()
    print(payload["tutorial"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
