#!/usr/bin/env python3
import argparse
import json
import sys

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
    registration_was_new = False

    def mutate_registry(registry: dict) -> dict:
        nonlocal registration_was_new
        existing = find_registration_by_session_id(registry, session_id)
        if existing is not None:
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
        registration = build_registration_record(session_id, alias)
        registry["registrations"].append(registration)
        return registration

    registration = update_registry(mutate_registry)
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
