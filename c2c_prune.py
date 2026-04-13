#!/usr/bin/env python3
import argparse
import json

from c2c_registry import load_registry, prune_registrations, update_registry
from claude_list_sessions import load_sessions


def compute_stale_entries(registry: dict, live_session_ids: set[str]) -> list[dict]:
    return [
        registration
        for registration in registry.get("registrations", [])
        if registration.get("session_id") not in live_session_ids
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prune stale entries from the c2c YAML registry."
    )
    parser.add_argument(
        "--json", action="store_true", help="emit JSON output"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would be pruned without modifying the registry",
    )
    args = parser.parse_args(argv)

    sessions = load_sessions()
    live_session_ids: set[str] = set()
    for session in sessions:
        sid = session.get("session_id")
        if isinstance(sid, str) and sid:
            live_session_ids.add(sid)

    if args.dry_run:
        registry = load_registry()
        removed = compute_stale_entries(registry, live_session_ids)
    else:

        def mutator(registry: dict) -> list[dict]:
            removed = compute_stale_entries(registry, live_session_ids)
            pruned = prune_registrations(registry, live_session_ids)
            registry["registrations"] = pruned["registrations"]
            return removed

        removed = update_registry(mutator)

    payload = {
        "pruned": [
            {"alias": entry.get("alias", ""), "session_id": entry.get("session_id", "")}
            for entry in removed
        ],
        "count": len(removed),
        "dry_run": args.dry_run,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not removed:
        print("No stale entries to prune.")
        return 0

    action = "Would prune" if args.dry_run else "Pruned"
    for entry in removed:
        print(f"{action}: {entry.get('alias', '?')} ({entry.get('session_id', '?')})")
    print(f"\n{len(removed)} entr{'y' if len(removed) == 1 else 'ies'} {action.lower()}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
