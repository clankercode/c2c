#!/usr/bin/env python3
# DEPRECATED — PTY injection path. See docs/known-issues.md for current delivery paths.
"""Auto-delivery daemon: watches opencode-local inbox and PTY-wakes the TUI.

Unlike c2c_deliver_inbox.py (which injects message CONTENT into the PTY,
tagging it source=pty), this script injects a minimal wake-up COMMAND that
tells the TUI to drain its inbox via its own MCP tools. The actual messages
travel broker-native (not PTY), so opencode-local can process them with full
broker metadata intact.

Usage:
    python3 c2c_opencode_wake_daemon.py [options]

    --session-id     broker session id to watch (default: opencode-local)
    --terminal-pid   PTY master pid (ghostty/tmux/etc)
    --pts            pts number
    --broker-root    broker directory
    --interval       poll interval in seconds when inotifywait unavailable
    --min-inject-gap minimum seconds between PTY injections (default: 15)
    --submit-delay   seconds to wait between bracketed paste and Enter
    --dry-run        print what would be injected, don't actually inject
    --once           drain once and exit
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent

import sys as _sys
if str(ROOT) not in _sys.path:
    _sys.path.insert(0, str(ROOT))
import c2c_pty_inject  # pure-Python pidfd_getfd backend

WAKE_PROMPT = (
    "You have pending c2c direct messages. "
    "Please call mcp__c2c__poll_inbox right now (no arguments). "
    "For EACH message in the result, call mcp__c2c__send with "
    "from_alias='opencode-local', to_alias=<the from_alias field of that message>, "
    "content=<your reply>. Do this before doing anything else."
)


def default_broker_root() -> Path:
    env = os.environ.get("C2C_MCP_BROKER_ROOT", "").strip()
    if env:
        return Path(env)
    try:
        import c2c_mcp
        return Path(c2c_mcp.default_broker_root())
    except Exception:
        return ROOT / ".git" / "c2c" / "mcp"


def inbox_path(broker_root: Path, session_id: str) -> Path:
    return broker_root / f"{session_id}.inbox.json"


def inbox_has_messages(path: Path) -> bool:
    try:
        raw = path.read_text(encoding="utf-8").strip()
        if not raw or raw == "[]":
            return False
        data = json.loads(raw)
        return isinstance(data, list) and len(data) > 0
    except Exception:
        return False


def pty_inject(
    terminal_pid: int,
    pts: int,
    message: str,
    *,
    dry_run: bool,
    submit_delay: float | None,
) -> bool:
    if dry_run:
        print(f"[dry-run] would inject to terminal_pid={terminal_pid} pts={pts}: {message[:80]}...")
        return True
    try:
        c2c_pty_inject.inject(
            int(terminal_pid),
            pts,
            message,
            submit_delay=submit_delay,
        )
        return True
    except Exception as exc:
        print(f"[wake-daemon] pty_inject error: {exc}", file=sys.stderr)
        return False


def watch_with_inotifywait(inbox: Path, timeout: float = 30.0) -> bool:
    """Wait up to timeout seconds for inbox modification. Returns True if event."""
    try:
        if inbox.exists():
            result = subprocess.run(
                ["inotifywait", "-q", "-e", "close_write", "-t", str(int(timeout)),
                 "--format", "%e", str(inbox)],
                capture_output=True, text=True, timeout=timeout + 5.0,
            )
            return result.returncode == 0 and bool(result.stdout.strip())
        else:
            result = subprocess.run(
                ["inotifywait", "-q", "-e", "create,close_write", "-t", str(int(timeout)),
                 "--format", "%e", str(inbox.parent)],
                capture_output=True, text=True, timeout=timeout + 5.0,
            )
            return result.returncode == 0 and bool(result.stdout.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def run(
    *,
    session_id: str,
    terminal_pid: int,
    pts: int,
    broker_root: Path,
    interval: float,
    min_inject_gap: float,
    submit_delay: float | None,
    dry_run: bool,
    once: bool,
) -> None:
    inbox = inbox_path(broker_root, session_id)
    last_inject_time = 0.0

    print(f"[wake-daemon] watching {inbox} → PTY terminal_pid={terminal_pid} pts={pts}")
    print(f"[wake-daemon] min_inject_gap={min_inject_gap}s interval={interval}s")

    while True:
        if inbox_has_messages(inbox):
            now = time.monotonic()
            gap = now - last_inject_time
            if gap >= min_inject_gap:
                print(f"[wake-daemon] inbox has messages, injecting wake-up")
                ok = pty_inject(
                    terminal_pid,
                    pts,
                    WAKE_PROMPT,
                    dry_run=dry_run,
                    submit_delay=submit_delay,
                )
                if ok:
                    last_inject_time = now
            else:
                print(f"[wake-daemon] inbox has messages but injected {gap:.1f}s ago, waiting")

            if once:
                break

            # Brief pause then re-check (let TUI process the wake-up)
            time.sleep(min(interval, 5.0))
        else:
            if once:
                break
            if not watch_with_inotifywait(inbox, timeout=interval):
                time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PTY-wake daemon for OpenCode inbox auto-delivery")
    parser.add_argument("--session-id", default="opencode-local")
    parser.add_argument("--terminal-pid", type=int, required=True, help="PTY master pid (e.g. ghostty)")
    parser.add_argument("--pts", type=int, required=True, help="pts number")
    parser.add_argument("--broker-root", type=Path)
    parser.add_argument("--interval", type=float, default=10.0, help="poll interval in seconds")
    parser.add_argument("--min-inject-gap", type=float, default=15.0,
                        help="minimum seconds between PTY injections")
    parser.add_argument(
        "--submit-delay",
        type=float,
        default=None,
        help="seconds to wait between bracketed paste and Enter",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--once", action="store_true", help="inject once if inbox has messages and exit")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    broker_root = args.broker_root or default_broker_root()

    run(
        session_id=args.session_id,
        terminal_pid=args.terminal_pid,
        pts=args.pts,
        broker_root=broker_root,
        interval=args.interval,
        min_inject_gap=args.min_inject_gap,
        submit_delay=args.submit_delay,
        dry_run=args.dry_run,
        once=args.once,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
