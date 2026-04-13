#!/usr/bin/env python3
"""c2c status - compact swarm overview.

Shows alive peers with message counts (from broker archive) and room
membership in a single glance.  Useful for agent orientation after a
context-compaction restart.

Usage:
    c2c status [--json] [--broker-root DIR] [--min-messages N]
"""
from __future__ import annotations

import argparse
import datetime
import json
import time
from pathlib import Path

import c2c_mcp
from c2c_verify import GOAL_COUNT, verify_progress_broker


def _last_recv_ts(archive_dir: Path, session_id: str, alias: str) -> float | None:
    """Return the drained_at timestamp of the last message drained by a peer.

    Checks <session_id>.jsonl first, then <alias>.jsonl (named sessions).
    Returns None if no archive file exists or it has no parseable entries.
    """
    for stem in (session_id, alias):
        path = archive_dir / f"{stem}.jsonl"
        if not path.exists():
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in reversed(lines):
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
                ts = entry.get("drained_at")
                if isinstance(ts, (int, float)):
                    return float(ts)
            except json.JSONDecodeError:
                continue
    return None


def _last_sent_ts_by_alias(archive_dir: Path) -> dict[str, float]:
    """Scan all archive files and return the most recent drained_at per from_alias.

    This is the last time each peer's message appeared drained in any inbox —
    i.e. the last time they sent something that was subsequently received.
    """
    latest: dict[str, float] = {}
    if not archive_dir.exists():
        return latest
    for archive_file in archive_dir.glob("*.jsonl"):
        try:
            lines = archive_file.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in lines:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            from_alias = entry.get("from_alias") or ""
            if not from_alias or from_alias == "c2c-system":
                continue
            ts = entry.get("drained_at")
            if isinstance(ts, (int, float)):
                ts = float(ts)
                if ts > latest.get(from_alias, 0.0):
                    latest[from_alias] = ts
    return latest


def _fmt_age(ts: float | None, now: float) -> str:
    """Format a Unix timestamp as a human-readable age relative to now."""
    if ts is None:
        return "never"
    age = now - ts
    if age < 0:
        return "just now"
    if age < 60:
        return f"{int(age)}s ago"
    if age < 3600:
        return f"{int(age / 60)}m ago"
    if age < 86400:
        return f"{int(age / 3600)}h ago"
    return f"{int(age / 86400)}d ago"


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
    """Return a list of {room_id, alive_count, member_count, alive_members} for each room.

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
        alive_members = sorted(
            m.get("alias", "")
            for m in members
            if m.get("alias") in alive_aliases
        )
        alive_count = len(alive_members)
        summaries.append(
            {
                "room_id": room_dir.name,
                "member_count": member_count,
                "alive_count": alive_count,
                "alive_members": alive_members,
            }
        )
    return summaries


def swarm_status(broker_root: Path | None = None, min_messages: int = 1) -> dict:
    if broker_root is None:
        broker_root = c2c_mcp.default_broker_root()

    registrations = _load_broker_registry(broker_root)
    verify = verify_progress_broker(broker_root, min_messages=min_messages)
    participants = verify.get("participants", {})
    archive_dir = broker_root / "archive"
    last_sent_map = _last_sent_ts_by_alias(archive_dir)

    alive_peers = []
    dead_peers = []
    filtered_peer_count = 0
    for reg in registrations:
        alias = reg.get("alias") or ""
        if not alias:
            continue
        session_id = reg.get("session_id") or ""
        alive = c2c_mcp.broker_registration_is_alive(reg)
        counts = participants.get(alias, {"sent": 0, "received": 0})
        if alive and min_messages > 0 and counts["sent"] + counts["received"] < min_messages:
            filtered_peer_count += 1
            continue
        recv_ts = _last_recv_ts(archive_dir, session_id, alias)
        sent_ts = last_sent_map.get(alias)
        # last_active_ts is the most recent of last-received and last-sent
        candidates = [t for t in (recv_ts, sent_ts) if t is not None]
        last_ts = max(candidates) if candidates else None
        entry = {
            "alias": alias,
            "alive": alive,
            "sent": counts["sent"],
            "received": counts["received"],
            "goal_met": counts["sent"] >= GOAL_COUNT and counts["received"] >= GOAL_COUNT,
            "last_active_ts": last_ts,
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
        "filtered_peer_count": filtered_peer_count,
        "min_messages": min_messages,
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
    filtered_count = data.get("filtered_peer_count", 0)
    rooms = data["rooms"]
    goal_met_count = data["goal_met_count"]
    goal_total = data["goal_total"]
    overall = data["overall_goal_met"]

    now = time.time()
    print(f"c2c Swarm Status  {ts}")
    print("=" * 50)
    print()
    filtered_detail = (
        f", {filtered_count} filtered <{data.get('min_messages', 1)} msgs"
        if filtered_count
        else ""
    )
    print(
        f"Active Peers  ({len(alive_peers)} alive / {total} total, "
        f"{dead_count} dead{filtered_detail})"
    )
    if alive_peers:
        alias_w = max(len(e["alias"]) for e in alive_peers)
        for e in alive_peers:
            goal_tag = "  [goal_met]" if e["goal_met"] else ""
            age = _fmt_age(e.get("last_active_ts"), now)
            print(
                f"  {e['alias']:<{alias_w}}  alive"
                f"  sent={e['sent']:<5} recv={e['received']:<5}"
                f"  last={age}{goal_tag}"
            )
    else:
        print("  (no alive peers)")
    print()

    active_rooms = [r for r in rooms if r["member_count"] > 0]
    if active_rooms:
        print("Rooms")
        room_id_w = max(len(r["room_id"]) for r in active_rooms)
        for r in active_rooms:
            member_detail = ""
            if r.get("alive_members"):
                member_detail = "  [" + ", ".join(r["alive_members"]) + "]"
            print(
                f"  {r['room_id']:<{room_id_w}}  {r['alive_count']} alive / {r['member_count']} members{member_detail}"
            )
        print()

    if overall:
        print(f"Goal: ALL {goal_total} alive peers at goal_met  OK")
    else:
        print(
            f"Goal: {goal_met_count} / {goal_total} alive peers at goal_met"
            f"  (need all to reach sent>={GOAL_COUNT} AND recv>={GOAL_COUNT})"
        )
        blockers = [e for e in alive_peers if not e["goal_met"]]
        for e in blockers:
            needs = []
            if e["sent"] < GOAL_COUNT:
                needs.append(f"need {GOAL_COUNT - e['sent']} more sends")
            if e["received"] < GOAL_COUNT:
                needs.append(f"need {GOAL_COUNT - e['received']} more recvs")
            if needs:
                print(f"  Blocked by {e['alias']}: {', '.join(needs)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Show a compact swarm status overview."
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--broker-root", metavar="DIR")
    parser.add_argument(
        "--min-messages",
        type=int,
        default=1,
        help=(
            "Minimum total sent+received messages required for an alive peer "
            "to appear in compact status; use 0 to include zero-activity peers."
        ),
    )
    args = parser.parse_args(argv)

    broker_root = Path(args.broker_root) if args.broker_root else None
    data = swarm_status(broker_root, min_messages=args.min_messages)

    if args.json:
        print(json.dumps(data, indent=2))
        return 0

    print_status_report(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
