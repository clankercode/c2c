#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path

import c2c_mcp
import claude_send_msg
from c2c_registry import (
    allocate_unique_alias,
    build_registration_record,
    find_registration_by_session_id,
    load_alias_words,
    update_registry,
)
from claude_list_sessions import find_session, load_sessions


def onboarding_message(alias: str) -> str:
    return (
        "You are now registered for C2C.\n"
        f"Your alias is {alias}.\n"
        "Run c2c-whoami for your current details and tutorial.\n"
        "Run c2c-list to see other opted-in sessions.\n"
        "If Bash approval allows it, reply with c2c-send <alias> <message...>.\n"
        "If Bash is not available or not approved, reply as a normal assistant message instead."
    )


def sync_broker_registry_from_env() -> None:
    broker_root = Path(
        os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root()
    )
    c2c_mcp.sync_broker_registry(broker_root)


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


def rollback_registration(session_id: str, alias: str) -> None:
    def mutate_registry(registry: dict) -> None:
        registry["registrations"] = [
            registration
            for registration in registry.get("registrations", [])
            if not (
                registration.get("session_id") == session_id
                and registration.get("alias") == alias
            )
        ]

    update_registry(mutate_registry)
    sync_broker_registry_from_env()


def send_onboarding_message(session: dict, alias: str) -> None:
    claude_send_msg.send_message_to_session(
        session,
        onboarding_message(alias),
        event="onboarding",
        sender_name="c2c-register",
        sender_alias=alias,
    )


def register_session(identifier: str) -> tuple[dict, dict, bool]:
    sessions = load_sessions()
    session = find_session(identifier, sessions)
    if session is None:
        raise ValueError(f"session not found: {identifier}")

    session_id = session["session_id"]
    session_pid = session.get("pid")
    session_pid = session_pid if isinstance(session_pid, int) else None
    if session_pid is not None:
        session_pid_start_time = read_pid_start_time(session_pid)
        if session_pid_start_time is None:
            # Fixture pids and races where the target has already exited still
            # get an integer marker so downstream liveness checks treat the
            # row as non-legacy rather than immortal.
            session_pid_start_time = 0
    else:
        session_pid_start_time = None
    registration_was_new = False

    def mutate_registry(registry: dict) -> dict:
        nonlocal registration_was_new
        existing = find_registration_by_session_id(registry, session_id)
        if existing is not None:
            if session_pid is not None:
                existing["pid"] = session_pid
                if session_pid_start_time is not None:
                    existing["pid_start_time"] = session_pid_start_time
            return existing

        registration_was_new = True
        words = load_alias_words()
        alias = allocate_unique_alias(
            words,
            {
                registration["alias"]
                for registration in registry.get("registrations", [])
            },
        )
        registration = build_registration_record(
            session_id,
            alias,
            pid=session_pid,
            pid_start_time=session_pid_start_time,
        )
        registry["registrations"].append(registration)
        return registration

    registration = update_registry(mutate_registry)
    sync_broker_registry_from_env()
    return session, registration, registration_was_new


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Register a live Claude session for c2c alias lookup."
    )
    parser.add_argument("session")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        session, registration, registration_was_new = register_session(args.session)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1

    if registration_was_new:
        try:
            send_onboarding_message(session, registration["alias"])
        except Exception as error:
            rollback_registration(registration["session_id"], registration["alias"])
            print(str(error), file=sys.stderr)
            return 1

    payload = {
        "name": session.get("name", ""),
        "session_id": registration["session_id"],
        "alias": registration["alias"],
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"Registered alias {registration['alias']} for {payload['session_id']}")
    print("Use c2c-list --json to inspect opted-in sessions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
