#!/usr/bin/env python3
"""c2c status - compact swarm overview.

Shows alive peers with message counts (from broker archive) and room
membership in a single glance.  Useful for agent orientation after a
context-compaction restart.

Usage:
    c2c status [--json] [--broker-root DIR]
"""
from __future__ import annotations

import argparse
import datetime
import json
from pathlib import Path

import c2c_mcp
from c2c_verify import GOAL_COUNT, verify_progress_broker


def _load_broker_registry(broker_root: Path) -> list[dict]:
    registry_path = broker_root / "registry.json"
    if not registry_path.exists():
        return []
    try:
        raw = json.loads(registry_path.read_text(encoding="utf-8"))
        return raw if isinstance(raw, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def _load_room_summary(broker_root: Path, registry: list[dict]) -> list[dict]:
    """Return a list of {room_id, alive_count, member_count} for each room.

    Room member entries only have (alias, session_id) - no PID. Cross-reference
    with the broker registry to determine liveness.
    """
    rooms_dir = broker_root / "rooms"
    if not rooms_dir.exists():
        return []

    # Build a set of alive aliases from the registry for O(1) lookup.
    alive_aliases: set[str] = {
        reg["alias"]
        for reg in registry
        if reg.get("alias") and c2c_mcp.broker_registration_is_alive(reg)
    }

    summaries = []
    for room_dir in sorted(rooms_dir.iterdir()):
        if not room_dir.is_dir():
            continue
        members_path = room_dir / "members.json"
        if not members_path.exists():
            continue
        try:
            members = json.loads(members_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            members = []
        member_count = len(members)
        alive_count = sum(
            1 for m in members if m.get("alias") in alive_aliases
        )
        summaries.append(
            {
                "room_id": room_dir.name,
                "member_count": member_count,
                "alive_count": alive_count,
            }
        )
    return summaries


def swarm_status(broker_root: Path | None = None) -> dict:
    if broker_root is None:
        broker_root = c2c_mcp.default_broker_root()

    registrations = _load_broker_registry(broker_root)
    verify = verify_progress_broker(broker_root)
    participants = verify.get("participants", {})

    alive_peers = []
    dead_peers = []
    for reg in registrations:
        alias = reg.get("alias") or ""
        if not alias:
            continue
        alive = c2c_mcp.broker_registration_is_alive(reg)
        counts = participants.get(alias, {"sent": 0, "received": 0})
        entry = {
            "alias": alias,
            "alive": alive,
            "sent": counts["sent"],
            "received": counts["received"],
            "goal_met": counts["sent"] >= GOAL_COUNT and counts["received"] >= GOAL_COUNT,
        }
        if alive:
            alive_peers.append(entry)
        else:
            dead_peers.append(entry)

    # Sort alive peers: goal_met first, then by alias.
    alive_peers.sort(key=lambda e: (not e["goal_met"], e["alias"]))

    rooms = _load_room_summary(broker_root, registrations)

    goal_met_count = sum(1 for e in alive_peers if e["goal_met"])

    return {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "alive_peers": alive_peers,
        "dead_peer_count": len(dead_peers),
        "total_peer_count": len(registrations),
        "rooms": rooms,
        "goal_met_count": goal_met_count,
        "goal_total": len(alive_peers),
        "overall_goal_met": goal_met_count == len(alive_peers) and len(alive_peers) > 0,
    }


def print_status_report(data: dict) -> None:
    ts = data["ts"]
    alive_peers = data["alive_peers"]
    dead_count = data["dead_peer_count"]
    total = data["total_peer_count"]
    rooms = data["rooms"]
    goal_met_count = data["goal_met_count"]
    goal_total = data["goal_total"]
    overall = data["overall_goal_met"]

    print(f"c2c Swarm Status  {ts}")
    print("=" * 50)
    print()
    print(f"Active Peers  ({len(alive_peers)} alive / {total} total, {dead_count} dead)")
    if alive_peers:
        alias_w = max(len(e["alias"]) for e in alive_peers)
        for e in alive_peers:
            goal_tag = "  [goal_met]" if e["goal_met"] else ""
            print(
                f"  {e['alias']:<{alias_w}}  alive"
                f"  sent={e['sent']:<5} recv={e['received']:<5}{goal_tag}"
            )
    else:
        print("  (no alive peers)")
    print()

    if rooms:
        print("Rooms")
        room_id_w = max(len(r["room_id"]) for r in rooms)
        for r in rooms:
            print(
                f"  {r['room_id']:<{room_id_w}}  {r['alive_count']} alive / {r['member_count']} members"
            )
        print()

    if overall:
        print(f"Goal: ALL {goal_total} alive peers at goal_met  OK")
    else:
        print(
            f"Goal: {goal_met_count} / {goal_total} alive peers at goal_met"
            f"  (need all to reach sent>={GOAL_COUNT} AND recv>={GOAL_COUNT})"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Show a compact swarm status overview."
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--broker-root", metavar="DIR")
    args = parser.parse_args(argv)

    broker_root = Path(args.broker_root) if args.broker_root else None
    data = swarm_status(broker_root)

    if args.json:
        print(json.dumps(data, indent=2))
        return 0

    print_status_report(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
