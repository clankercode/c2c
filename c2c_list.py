#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path

from c2c_registry import (
    find_registration_by_session_id,
    load_registry,
)
from claude_list_sessions import load_sessions


def live_sessions_with_aliases() -> tuple[list[dict], dict]:
    """Return (live sessions, registrations_by_id restricted to live sessions).

    Read-only: the on-disk YAML registry is never mutated here. Stale entries
    for offline sessions remain on disk so that a restarting agent can recover
    its prior alias via c2c_register's session-id lookup — see
    .collab/findings/2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md.
    """
    sessions = load_sessions()
    sessions_by_id = {session.get("session_id"): session for session in sessions}

    registry = load_registry()
    registrations_by_id = {
        registration["session_id"]: registration
        for registration in registry.get("registrations", [])
        if registration.get("session_id") in sessions_by_id
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
        else:
            print("No opted-in sessions. Use c2c-register to add one.")
    else:
        for row in rows:
            print(f"{row['alias']}\t{row['name']}\t{row['session_id']}")

    if not args.all and not args.json:
        try:
            broker_count = len(list_broker_peers())
        except Exception:
            broker_count = 0
        if broker_count > len(rows):
            extra = broker_count - len(rows)
            print(
                f"\n({extra} more peer{'s' if extra != 1 else ''} in broker"
                " registry — use --broker to see all)"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
