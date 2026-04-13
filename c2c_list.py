#!/usr/bin/env python3
import argparse
import json
import os
import re
import time
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


def _pid_alive(pid: int, pid_start_time: int | None) -> bool | None:
    """Check if a pid is alive using /proc. Returns None if no pid."""
    if not pid:
        return None
    proc_path = Path(f"/proc/{pid}")
    if not proc_path.exists():
        return False
    if pid_start_time:
        try:
            stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
            fields = stat.split()
            if len(fields) > 21:
                start = int(fields[21])
                if start != pid_start_time:
                    return False  # pid reused
        except (OSError, ValueError):
            pass
    return True


def _peer_rooms(broker_root: Path, alias: str) -> list[str]:
    """Return room IDs the peer is currently a member of."""
    rooms_dir = broker_root / "rooms"
    if not rooms_dir.exists():
        return []
    result = []
    for room_dir in sorted(rooms_dir.iterdir()):
        if not room_dir.is_dir():
            continue
        members_file = room_dir / "members.json"
        if not members_file.exists():
            continue
        try:
            members = json.loads(members_file.read_text(encoding="utf-8"))
            if any(m.get("alias") == alias for m in members):
                result.append(room_dir.name)
        except (OSError, json.JSONDecodeError):
            pass
    return result


_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def _infer_client_type(alias: str, session_id: str) -> str:
    if _UUID_RE.fullmatch(session_id):
        return "claude-code"
    if session_id.startswith("codex") or alias == "codex" or alias.startswith("codex-"):
        return "codex"
    if session_id.startswith("opencode") or alias.startswith("opencode"):
        return "opencode"
    if alias.startswith("kimi-"):
        return "kimi"
    if alias.startswith("crush-"):
        return "crush"
    return "?"


def _registered_ago(registered_at: float | None) -> str | None:
    if registered_at is None:
        return None
    try:
        age_s = time.time() - registered_at
        if age_s < 60:
            return f"{int(age_s)}s ago"
        elif age_s < 3600:
            return f"{int(age_s / 60)}m ago"
        else:
            return f"{int(age_s / 3600)}h ago"
    except (ValueError, OverflowError):
        return None


def _last_seen_str(broker_root: Path, session_id: str) -> str | None:
    inbox_path = broker_root / f"{session_id}.inbox.json"
    if not inbox_path.exists():
        return None
    try:
        age_s = time.time() - inbox_path.stat().st_mtime
        if age_s < 60:
            return f"{int(age_s)}s ago"
        elif age_s < 3600:
            return f"{int(age_s / 60)}m ago"
        else:
            return f"{int(age_s / 3600)}h ago"
    except OSError:
        return None


def list_broker_peers() -> list[dict]:
    """Return every registration currently in the broker registry.

    Mirrors what `mcp__c2c__list` / `Broker.list_registrations` return on the
    OCaml side, but callable from the plain CLI so operators can see the
    cross-client peer set (broker-only peers like codex-local and opencode
    participants never show up in YAML-based `c2c list`).

    Includes `alive` (bool or null) and `rooms` (list of room IDs).
    """
    from c2c_mcp import default_broker_root, load_broker_registrations

    broker_root = Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    rows = []
    for registration in load_broker_registrations(broker_root / "registry.json"):
        alias = str(registration.get("alias", ""))
        try:
            pid = int(str(registration.get("pid") or 0))
        except (ValueError, TypeError):
            pid = 0
        try:
            pst_raw = registration.get("pid_start_time")
            pid_start_time: int | None = int(str(pst_raw)) if pst_raw is not None else None
        except (ValueError, TypeError):
            pid_start_time = None
        try:
            ra_raw = registration.get("registered_at")
            registered_at: float | None = float(str(ra_raw)) if ra_raw is not None else None
        except (ValueError, TypeError):
            registered_at = None
        session_id = str(registration.get("session_id", ""))
        # Prefer registered_at for last_seen; fall back to inbox mtime
        last_seen = _registered_ago(registered_at) or _last_seen_str(broker_root, session_id)
        rows.append(
            {
                "alias": alias,
                "session_id": session_id,
                "pid": pid or None,
                "alive": _pid_alive(pid, pid_start_time),
                "rooms": _peer_rooms(broker_root, alias),
                "client_type": _infer_client_type(alias, session_id),
                "last_seen": last_seen,
                "registered_at": registered_at,
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
        # Sort: alive first, then unknown, then dead; within groups, alphabetical
        def _sort_key(p: dict) -> tuple:
            alive = p.get("alive")
            order = 0 if alive is True else (1 if alive is None else 2)
            return (order, p.get("alias", ""))
        peers = sorted(peers, key=_sort_key)
        if not peers:
            print("No broker peers. Is the MCP server running?")
            return 0
        for peer in peers:
            alive = peer.get("alive")
            status = "alive" if alive is True else ("dead" if alive is False else "?")
            rooms = ", ".join(peer.get("rooms") or []) or "-"
            client = peer.get("client_type") or "?"
            seen = peer.get("last_seen") or "-"
            print(f"{peer['alias']}\t[{status}]\t{client}\t{seen}\t{rooms}")
        dead_count = sum(1 for p in peers if p.get("alive") is False)
        if dead_count > 0:
            print(f"\n({dead_count} dead peer{'s' if dead_count != 1 else ''} — run `c2c sweep` to clean up)")
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
