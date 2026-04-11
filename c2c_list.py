#!/usr/bin/env python3
import argparse
import json

from c2c_registry import (
    find_registration_by_session_id,
    prune_registrations,
    update_registry,
)
from claude_list_sessions import load_sessions


def live_sessions_with_aliases() -> tuple[list[dict], dict]:
    sessions = load_sessions()
    sessions_by_id = {session.get("session_id"): session for session in sessions}

    def mutate_registry(registry: dict) -> dict:
        pruned_registry = prune_registrations(registry, set(sessions_by_id))
        registry["registrations"] = pruned_registry["registrations"]
        return registry

    pruned_registry = update_registry(mutate_registry)
    registrations_by_id = {
        registration["session_id"]: registration
        for registration in pruned_registry.get("registrations", [])
    }
    return sessions, registrations_by_id


def list_registered_sessions() -> list[dict]:
    sessions, registrations_by_id = live_sessions_with_aliases()
    sessions_by_id = {session.get("session_id"): session for session in sessions}

    rows = []
    for session_id, registration in registrations_by_id.items():
        session = sessions_by_id[session_id]
        rows.append(
            {
                "alias": registration["alias"],
                "name": session.get("name", ""),
                "session_id": session_id,
            }
        )
    return rows


def list_sessions(include_all: bool = False) -> list[dict]:
    sessions, registrations_by_id = live_sessions_with_aliases()
    rows = []
    for session in sessions:
        registration = find_registration_by_session_id(
            {"registrations": list(registrations_by_id.values())},
            session.get("session_id", ""),
        )
        if registration is None and not include_all:
            continue
        rows.append(
            {
                "alias": registration["alias"] if registration is not None else "",
                "name": session.get("name", ""),
                "session_id": session.get("session_id", ""),
            }
        )
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="List opted-in c2c sessions.")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    rows = list_sessions(include_all=args.all)
    payload = {"sessions": rows}
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not rows:
        if args.all:
            print("No live Claude sessions found.")
            return 0
        print("No opted-in sessions. Use c2c-register to add one.")
        return 0

    for row in rows:
        print(f"{row['alias']}\t{row['name']}\t{row['session_id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
