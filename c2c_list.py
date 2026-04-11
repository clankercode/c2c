#!/usr/bin/env python3
import argparse
import json

from c2c_registry import prune_registrations, update_registry
from claude_list_sessions import load_sessions


def list_registered_sessions() -> list[dict]:
    sessions = load_sessions()
    sessions_by_id = {session.get("session_id"): session for session in sessions}

    def mutate_registry(registry: dict) -> dict:
        pruned_registry = prune_registrations(registry, set(sessions_by_id))
        registry["registrations"] = pruned_registry["registrations"]
        return registry

    pruned_registry = update_registry(mutate_registry)

    rows = []
    for registration in pruned_registry.get("registrations", []):
        session = sessions_by_id[registration["session_id"]]
        rows.append(
            {
                "alias": registration["alias"],
                "name": session.get("name", ""),
                "session_id": registration["session_id"],
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="List opted-in c2c sessions.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    rows = list_registered_sessions()
    payload = {"sessions": rows}
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not rows:
        print("No opted-in sessions. Use c2c-register to add one.")
        return 0

    for row in rows:
        print(f"{row['alias']}\t{row['name']}\t{row['session_id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
