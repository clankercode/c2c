#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

import c2c_poker


def resolve_target(args: argparse.Namespace) -> tuple[int, str, str | None]:
    if args.claude_session:
        return c2c_poker.resolve_claude_session(args.claude_session)
    if args.pid is not None:
        return c2c_poker.resolve_pid(args.pid)
    return int(args.terminal_pid), str(args.pts), None


def build_result(
    *,
    client: str,
    terminal_pid: int,
    pts: str,
    payload: str,
    dry_run: bool,
) -> dict[str, Any]:
    return {
        "ok": True,
        "client": client,
        "terminal_pid": terminal_pid,
        "pts": pts,
        "payload": payload,
        "dry_run": dry_run,
        "sent_at": time.time(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject one C2C message into a live Claude, Codex, OpenCode, or generic TTY client."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")
    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument(
        "--client",
        choices=["claude", "codex", "opencode", "generic"],
        default="generic",
        help="client label for result metadata (default: generic)",
    )
    parser.add_argument("--event", default="message")
    parser.add_argument("--from", dest="sender", default="c2c-inject")
    parser.add_argument("--alias", default="")
    parser.add_argument("--raw", action="store_true", help="do not wrap in <c2c>")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("message", nargs="+")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")

    terminal_pid, pts, _transcript = resolve_target(args)
    message = " ".join(args.message)
    payload = c2c_poker.render_payload(
        message,
        args.event,
        args.sender,
        args.alias,
        args.raw,
        source="pty",
        source_tool="c2c_inject",
    )
    if not args.dry_run:
        c2c_poker.inject(terminal_pid, pts, payload)

    result = build_result(
        client=args.client,
        terminal_pid=terminal_pid,
        pts=pts,
        payload=payload,
        dry_run=args.dry_run,
    )
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        action = "would inject" if args.dry_run else "injected"
        print(f"{action} into {args.client} terminal pid={terminal_pid} pts={pts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
