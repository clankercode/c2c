#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

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


def list_broker_peers() -> list[dict]:
    """Return every registration currently in the broker registry.

    Mirrors what `mcp__c2c__list` / `Broker.list_registrations` return on the
    OCaml side, but callable from the plain CLI so operators can see the
    cross-client peer set (broker-only peers like codex-local and opencode
    participants never show up in YAML-based `c2c list`).
    """
    from c2c_mcp import default_broker_root, load_broker_registrations

    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    rows = []
    for registration in load_broker_registrations(broker_root / "registry.json"):
        rows.append(
            {
                "alias": str(registration.get("alias", "")),
                "session_id": str(registration.get("session_id", "")),
            }
        )
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="List opted-in c2c sessions.")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--broker",
        action="store_true",
        help="list peers registered in the broker registry (includes broker-only "
        "peers such as codex-local and opencode participants)",
    )
    args = parser.parse_args(argv)

    if args.broker:
        peers = list_broker_peers()
        if args.json:
            print(json.dumps({"peers": peers}, indent=2))
            return 0
        if not peers:
            print("No broker peers. Is the MCP server running?")
            return 0
        for peer in peers:
            print(f"{peer['alias']}\t{peer['session_id']}")
        return 0

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
