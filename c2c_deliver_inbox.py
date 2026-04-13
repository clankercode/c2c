#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import c2c_inject
import c2c_poll_inbox
import c2c_poker


def peek_inbox(broker_root: Path, session_id: str) -> list[dict[str, Any]]:
    path = c2c_poll_inbox.inbox_path(broker_root, session_id)
    with c2c_poll_inbox.inbox_lock(broker_root, session_id):
        if not path.exists():
            return []
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        if not isinstance(loaded, list):
            raise ValueError(f"inbox is not a JSON list: {path}")
        return [item for item in loaded if isinstance(item, dict)]


def message_payload(message: dict[str, Any]) -> str:
    content = str(message.get("content", ""))
    sender = str(message.get("from_alias", "") or "c2c")
    alias = str(message.get("to_alias", "") or "")
    return c2c_poker.render_payload(
        content, event="message", sender=sender, alias=alias, raw=False
    )


def build_result(
    *,
    session_id: str,
    broker_root: Path,
    source: str,
    client: str,
    terminal_pid: int,
    pts: str,
    messages: list[dict[str, Any]],
    dry_run: bool,
) -> dict[str, Any]:
    return {
        "ok": True,
        "session_id": session_id,
        "broker_root": str(broker_root),
        "source": source,
        "target": {"client": client, "terminal_pid": terminal_pid, "pts": pts},
        "messages": messages,
        "delivered": 0 if dry_run else len(messages),
        "dry_run": dry_run,
        "sent_at": time.time(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Drain a C2C broker inbox and inject queued messages into a live client terminal."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")
    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument("--session-id", help="broker session id to deliver")
    parser.add_argument("--broker-root", type=Path, help="broker root directory")
    parser.add_argument("--file-fallback", action="store_true")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument(
        "--client",
        choices=["claude", "codex", "opencode", "generic"],
        default="generic",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="peek and render without draining or injecting",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")

    session_id = c2c_poll_inbox.resolve_session_id(args.session_id)
    broker_root = args.broker_root or c2c_poll_inbox.default_broker_root()
    terminal_pid, pts, _transcript = c2c_inject.resolve_target(args)

    try:
        if args.dry_run:
            source = "peek"
            messages = peek_inbox(broker_root, session_id)
        else:
            source, messages = c2c_poll_inbox.poll_inbox(
                broker_root=broker_root,
                session_id=session_id,
                timeout=args.timeout,
                force_file=args.file_fallback,
                allow_file_fallback=True,
            )
            for message in messages:
                c2c_poker.inject(terminal_pid, pts, message_payload(message))
    except Exception as exc:
        print(f"[c2c-deliver-inbox] {exc}", file=sys.stderr)
        return 1

    result = build_result(
        session_id=session_id,
        broker_root=broker_root,
        source=source,
        client=args.client,
        terminal_pid=terminal_pid,
        pts=pts,
        messages=messages,
        dry_run=args.dry_run,
    )
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        action = "would deliver" if args.dry_run else "delivered"
        print(f"{action} {result['delivered']} message(s) to {args.client}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
