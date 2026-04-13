#!/usr/bin/env python3
"""Python CLI for c2c N:N rooms.

Operates directly on the broker filesystem under
.git/c2c/mcp/rooms/<room_id>/ so it works as a broker-only fallback
for any host client (Claude, Codex, OpenCode) without MCP.

When the OCaml broker gains MCP room tools (join_room, send_room,
etc.), these become the CLI wrappers that call through; for now they
do direct file manipulation matching the schema from the rooms design
doc (.collab/findings/2026-04-13T04-00-00Z-storm-echo-broadcast-and-rooms-design.md).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import c2c_mcp


def default_broker_root() -> Path:
    return Path(
        os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root()
    )


def rooms_root(broker_root: Path | None = None) -> Path:
    return (broker_root or default_broker_root()) / "rooms"


def room_dir(room_id: str, broker_root: Path | None = None) -> Path:
    return rooms_root(broker_root) / room_id


# --- locking (matches broker POSIX lockf sidecar pattern) ---


class _LockContext:
    def __init__(self, lock_path: Path):
        self._lock_path = lock_path
        self._fd: int | None = None

    def __enter__(self) -> "_LockContext":
        self._lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = os.open(
            str(self._lock_path), os.O_WRONLY | os.O_CREAT, 0o600
        )
        fcntl.lockf(self._fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: object) -> None:
        if self._fd is not None:
            fcntl.lockf(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None


def members_lock(rdir: Path) -> _LockContext:
    return _LockContext(rdir / "members.lock")


def history_lock(rdir: Path) -> _LockContext:
    return _LockContext(rdir / "history.lock")


# --- atomic JSON write (matches broker pattern) ---


def write_json_atomic(path: Path, data: object) -> None:
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        json.dump(data, handle)
        handle.flush()
        os.fsync(handle.fileno())
        tmp = Path(handle.name)
    os.chmod(str(tmp), 0o600)
    os.replace(tmp, path)


def load_json_list(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, dict)]


# --- room operations ---


def init_room(room_id: str, broker_root: Path | None = None) -> dict:
    rdir = room_dir(room_id, broker_root)
    rdir.mkdir(parents=True, exist_ok=True)
    members_path = rdir / "members.json"
    history_path = rdir / "history.jsonl"
    if not members_path.exists():
        write_json_atomic(members_path, [])
    if not history_path.exists():
        history_path.touch(mode=0o600)
    return {"ok": True, "room_id": room_id, "path": str(rdir)}


def join_room(
    room_id: str,
    alias: str,
    session_id: str,
    broker_root: Path | None = None,
) -> dict:
    rdir = room_dir(room_id, broker_root)
    init_room(room_id, broker_root)
    members_path = rdir / "members.json"
    with members_lock(rdir):
        members = load_json_list(members_path)
        already = any(
            m.get("alias") == alias and m.get("session_id") == session_id
            for m in members
        )
        existing = next(
            (
                m
                for m in members
                if m.get("alias") == alias or m.get("session_id") == session_id
            ),
            None,
        )
        joined_at = (
            existing.get("joined_at")
            if isinstance(existing, dict) and "joined_at" in existing
            else time.time()
        )
        member = {
            "alias": alias,
            "session_id": session_id,
            "joined_at": joined_at,
        }
        updated = [
            m
            for m in members
            if m.get("alias") != alias and m.get("session_id") != session_id
        ]
        updated.append(member)
        if updated != members:
            write_json_atomic(members_path, updated)
    return {
        "ok": True,
        "room_id": room_id,
        "alias": alias,
        "already_member": already,
    }


def leave_room(
    room_id: str, alias: str, broker_root: Path | None = None
) -> dict:
    rdir = room_dir(room_id, broker_root)
    members_path = rdir / "members.json"
    if not members_path.exists():
        return {"ok": False, "error": f"room not found: {room_id}"}
    with members_lock(rdir):
        members = load_json_list(members_path)
        before = len(members)
        members = [m for m in members if m.get("alias") != alias]
        write_json_atomic(members_path, members)
    removed = before - len(members)
    return {"ok": True, "room_id": room_id, "alias": alias, "removed": removed}


def send_room(
    room_id: str,
    from_alias: str,
    content: str,
    broker_root: Path | None = None,
) -> dict:
    broot = broker_root or default_broker_root()
    rdir = room_dir(room_id, broot)
    members_path = rdir / "members.json"
    history_path = rdir / "history.jsonl"
    if not members_path.exists():
        return {"ok": False, "error": f"room not found: {room_id}"}

    record = json.dumps(
        {"ts": time.time(), "from_alias": from_alias, "content": content},
        ensure_ascii=False,
    )

    with history_lock(rdir):
        with open(
            history_path,
            "a",
            encoding="utf-8",
            opener=lambda p, f: os.open(p, f, 0o600),
        ) as fh:
            fh.write(record + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    # fan out to members' inboxes (skip sender)
    with members_lock(rdir):
        members = load_json_list(members_path)

    sent_to: list[str] = []
    skipped: list[dict] = []
    for member in members:
        malias = member.get("alias", "")
        sid = member.get("session_id", "")
        if malias == from_alias:
            skipped.append({"alias": malias, "reason": "sender"})
            continue
        inbox_path = broot / f"{sid}.inbox.json"
        lock_path = broot / f"{sid}.inbox.lock"
        try:
            with _LockContext(lock_path):
                items = load_json_list(inbox_path)
                items.append(
                    {
                        "from_alias": from_alias,
                        "to_alias": f"{malias}@{room_id}",
                        "content": content,
                    }
                )
                write_json_atomic(inbox_path, items)
            sent_to.append(malias)
        except Exception as exc:
            skipped.append({"alias": malias, "reason": str(exc)})

    return {
        "ok": True,
        "room_id": room_id,
        "sent_to": sent_to,
        "skipped": skipped,
    }


def prune_dead_members(
    room_id: str,
    broker_root: Path | None = None,
    dry_run: bool = False,
) -> dict:
    """Remove members whose alias is not in the broker registry.

    Unlike `mcp__c2c__sweep`, this only modifies room member lists — it never
    touches registrations or inboxes. Safe to run while managed outer loops are
    active (no sweep footgun).

    Returns dict with: room_id, before_count, after_count, removed (list of alias)
    """
    broot = broker_root or default_broker_root()
    rdir = room_dir(room_id, broot)
    members_path = rdir / "members.json"
    if not members_path.exists():
        return {"ok": False, "error": f"room not found: {room_id}"}

    # Read registered aliases from registry.json (no lock needed: read-only snapshot)
    registered: set[str] = {
        reg.get("alias", "")
        for reg in load_json_list(broot / "registry.json")
        if reg.get("alias")
    }

    with members_lock(rdir):
        members = load_json_list(members_path)
        before = len(members)
        kept = [m for m in members if m.get("alias", "") in registered]
        removed = [m.get("alias", "?") for m in members if m.get("alias", "") not in registered]
        if not dry_run and removed:
            write_json_atomic(members_path, kept)

    return {
        "ok": True,
        "room_id": room_id,
        "before_count": before,
        "after_count": len(kept),
        "removed": removed,
        "dry_run": dry_run,
    }


def _read_pid_start_time(pid: int) -> int | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except OSError:
        return None
    tail_start = stat.rfind(")")
    if tail_start == -1 or tail_start + 2 >= len(stat):
        return None
    parts = stat[tail_start + 2 :].split()
    if len(parts) <= 19:
        return None
    try:
        return int(parts[19])
    except ValueError:
        return None


def _registration_alive(reg: dict | None) -> bool | None:
    if reg is None:
        return False
    pid = reg.get("pid")
    if not isinstance(pid, int):
        return None
    if not Path(f"/proc/{pid}").exists():
        return False
    start_time = reg.get("pid_start_time")
    if isinstance(start_time, int):
        return _read_pid_start_time(pid) == start_time
    return True


def _room_member_details(broot: Path, members: list[dict]) -> list[dict]:
    registrations = load_json_list(broot / "registry.json")
    by_session = {r.get("session_id"): r for r in registrations if r.get("session_id")}
    by_alias = {r.get("alias"): r for r in registrations if r.get("alias")}
    result = []
    for member in members:
        alias = str(member.get("alias", "?"))
        session_id = str(member.get("session_id", ""))
        reg = by_session.get(session_id) or by_alias.get(alias)
        result.append(
            {
                "alias": alias,
                "session_id": session_id,
                "alive": _registration_alive(reg),
            }
        )
    return result


def list_rooms(broker_root: Path | None = None) -> list[dict]:
    broot = broker_root or default_broker_root()
    rroot = rooms_root(broot)
    if not rroot.exists():
        return []
    result = []
    for entry in sorted(rroot.iterdir()):
        if not entry.is_dir():
            continue
        members_path = entry / "members.json"
        members = load_json_list(members_path)
        member_details = _room_member_details(broot, members)
        alive_count = sum(1 for m in member_details if m["alive"] is True)
        dead_count = sum(1 for m in member_details if m["alive"] is False)
        unknown_count = sum(1 for m in member_details if m["alive"] is None)
        result.append(
            {
                "room_id": entry.name,
                "member_count": len(members),
                "members": [m.get("alias", "?") for m in members],
                "alive_member_count": alive_count,
                "dead_member_count": dead_count,
                "unknown_member_count": unknown_count,
                "member_details": member_details,
            }
        )
    return result


def room_history(
    room_id: str, limit: int = 50, broker_root: Path | None = None
) -> list[dict]:
    rdir = room_dir(room_id, broker_root)
    history_path = rdir / "history.jsonl"
    if not history_path.exists():
        return []
    lines = history_path.read_text(encoding="utf-8").strip().splitlines()
    if limit > 0:
        lines = lines[-limit:]
    result = []
    for line in lines:
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return result


# --- CLI dispatch ---


def _broker_lookup(session_id: str) -> str | None:
    broot = default_broker_root()
    for reg in load_json_list(broot / "registry.json"):
        if reg.get("session_id") == session_id:
            alias = reg.get("alias")
            if isinstance(alias, str) and alias:
                return alias
    return None


def resolve_self_alias() -> str:
    """Best-effort alias resolution for the current session.

    Order: explicit env (C2C_MCP_SESSION_ID / C2C_SESSION_ID) → broker
    registry JSON → YAML registry via session discovery (walks /proc to
    find the parent Claude/Codex/OpenCode session and looks it up in
    the registry). Returns "unknown" only if all paths fail.
    """
    env_sid = os.environ.get("C2C_MCP_SESSION_ID", "").strip() or os.environ.get(
        "C2C_SESSION_ID", ""
    ).strip()
    if env_sid:
        alias = _broker_lookup(env_sid)
        if alias:
            return alias

    try:
        import c2c_whoami  # local import to avoid cycles at module load
        _session, registration = c2c_whoami.resolve_identity(None)
        if registration is not None:
            alias = registration.get("alias")
            if isinstance(alias, str) and alias:
                return alias
    except Exception:
        pass

    return "unknown"


def resolve_self_session_id() -> str:
    env_sid = os.environ.get("C2C_MCP_SESSION_ID", "").strip() or os.environ.get(
        "C2C_SESSION_ID", ""
    ).strip()
    if env_sid:
        return env_sid
    try:
        import c2c_whoami
        session, _registration = c2c_whoami.resolve_identity(None)
        sid = session.get("session_id")
        if isinstance(sid, str) and sid:
            return sid
    except Exception:
        pass
    return ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="c2c room operations")
    sub = parser.add_subparsers(dest="action")

    p_init = sub.add_parser("init", help="create a room")
    p_init.add_argument("room_id")
    p_init.add_argument("--json", action="store_true")

    p_join = sub.add_parser("join", help="join a room")
    p_join.add_argument("room_id")
    p_join.add_argument("--alias", default=None)
    p_join.add_argument("--session-id", default=None)
    p_join.add_argument("--json", action="store_true")

    p_leave = sub.add_parser("leave", help="leave a room")
    p_leave.add_argument("room_id")
    p_leave.add_argument("--alias", default=None)
    p_leave.add_argument("--json", action="store_true")

    p_send = sub.add_parser("send", help="send a message to a room")
    p_send.add_argument("room_id")
    p_send.add_argument("message", nargs="+")
    p_send.add_argument("--alias", default=None)
    p_send.add_argument("--json", action="store_true")

    p_history = sub.add_parser("history", help="read room history")
    p_history.add_argument("room_id")
    p_history.add_argument("--limit", type=int, default=50)
    p_history.add_argument("--json", action="store_true")

    p_list = sub.add_parser("list", help="list rooms")
    p_list.add_argument("--json", action="store_true")

    p_prune = sub.add_parser(
        "prune-dead",
        help="remove members whose alias is no longer in the broker registry (safe during outer loops)",
    )
    p_prune.add_argument("room_id")
    p_prune.add_argument("--dry-run", action="store_true", help="report without modifying")
    p_prune.add_argument("--json", action="store_true")

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.action is None:
        parser.print_help()
        return 2

    if args.action == "init":
        result = init_room(args.room_id)
    elif args.action == "join":
        alias = args.alias or resolve_self_alias()
        session_id = args.session_id or resolve_self_session_id()
        if not session_id:
            print("cannot resolve session_id; pass --session-id or set C2C_SESSION_ID", file=sys.stderr)
            return 1
        result = join_room(args.room_id, alias, session_id)
    elif args.action == "leave":
        alias = args.alias or resolve_self_alias()
        result = leave_room(args.room_id, alias)
    elif args.action == "send":
        alias = args.alias or resolve_self_alias()
        result = send_room(args.room_id, alias, " ".join(args.message))
    elif args.action == "history":
        result = room_history(args.room_id, limit=args.limit)
    elif args.action == "list":
        result = list_rooms()
    elif args.action == "prune-dead":
        result = prune_dead_members(args.room_id, dry_run=args.dry_run)
    else:
        parser.print_help()
        return 2

    if args.json or isinstance(result, list):
        print(json.dumps(result, indent=2))
    elif isinstance(result, dict):
        if not result.get("ok", True):
            print(result.get("error", "unknown error"), file=sys.stderr)
            return 1
        for key, value in result.items():
            if key == "ok":
                continue
            print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
