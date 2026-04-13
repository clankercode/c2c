#!/usr/bin/env python3
"""Read the c2c message archive for a session.

Every message drained via poll_inbox is archived to a per-session
append-only JSONL file at <broker_root>/archive/<session_id>.jsonl
before the live inbox is cleared. This script reads that archive and
prints it in human-readable or JSON format.

Accessible via `c2c history [--session-id S] [--limit N] [--json]`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import c2c_mcp


def default_broker_root() -> Path:
    return Path(os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root())


def resolve_session_id(value: str | None) -> str | None:
    if value:
        return value
    for name in ("C2C_MCP_SESSION_ID", "RUN_CLAUDE_INST_C2C_SESSION_ID",
                 "RUN_CODEX_INST_C2C_SESSION_ID"):
        candidate = os.environ.get(name, "").strip()
        if candidate:
            return candidate
    return None


def archive_path(broker_root: Path, session_id: str) -> Path:
    return broker_root / "archive" / f"{session_id}.jsonl"


def read_archive(broker_root: Path, session_id: str, limit: int) -> list[dict]:
    path = archive_path(broker_root, session_id)
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    entries = []
    for line in lines:
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    # Return the most recent `limit` entries
    if limit > 0:
        entries = entries[-limit:]
    return entries


def list_archive_sessions(broker_root: Path) -> list[str]:
    archive_dir = broker_root / "archive"
    if not archive_dir.exists():
        return []
    return sorted(
        p.stem for p in archive_dir.iterdir()
        if p.suffix == ".jsonl"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read the c2c message archive for a session.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Archive path: <broker_root>/archive/<session_id>.jsonl",
    )
    parser.add_argument(
        "--session-id", "-s",
        metavar="ID",
        help="Session ID to read archive for (defaults to current session env)",
    )
    parser.add_argument(
        "--limit", "-n",
        type=int,
        default=50,
        metavar="N",
        help="Maximum number of entries to return, newest first (default: 50; 0 = all)",
    )
    parser.add_argument(
        "--broker-root",
        metavar="DIR",
        help="Override broker root directory",
    )
    parser.add_argument(
        "--list-sessions",
        action="store_true",
        help="List all sessions that have archive files, then exit",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON output",
    )
    args = parser.parse_args(argv)

    broker_root = Path(args.broker_root) if args.broker_root else default_broker_root()

    if args.list_sessions:
        sessions = list_archive_sessions(broker_root)
        if args.json:
            print(json.dumps({"sessions": sessions}))
        else:
            if sessions:
                for s in sessions:
                    print(s)
            else:
                print("[c2c-history] no archive files found", file=sys.stderr)
        return 0

    session_id = resolve_session_id(args.session_id)
    if not session_id:
        print(
            "[c2c-history] error: no session_id — pass --session-id or set C2C_MCP_SESSION_ID",
            file=sys.stderr,
        )
        return 1

    entries = read_archive(broker_root, session_id, args.limit)

    if args.json:
        print(json.dumps({"session_id": session_id, "count": len(entries), "messages": entries}))
    else:
        if not entries:
            print(f"[c2c-history] no archived messages for {session_id}", file=sys.stderr)
        else:
            count = len(entries)
            print(f"[c2c-history] {count} archived message(s) for {session_id}")
            for entry in entries:
                from_a = entry.get("from_alias", "?")
                to_a = entry.get("to_alias", "?")
                drained = entry.get("drained_at", "?")
                content = entry.get("content", "")
                print(f"\n--- from={from_a} to={to_a} drained_at={drained}")
                print(content)

    return 0


if __name__ == "__main__":
    sys.exit(main())
