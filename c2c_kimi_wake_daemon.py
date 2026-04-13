#!/usr/bin/env python3
"""Auto-delivery daemon: watches a Kimi Code session inbox and PTY-wakes the TUI.

Same pattern as c2c_opencode_wake_daemon.py.  Kimi Code is a terminal-based
CLI that accepts user prompts and calls MCP tools in each turn.  When a new
c2c message arrives in the broker inbox, this daemon writes a short wake
prompt directly to /dev/pts/<N> that tells the Kimi agent to call
mcp__c2c__poll_inbox.

Uses c2c_pts_inject.inject() — plain text write to /dev/pts/<N> — NOT the
pty_inject binary.  The pty_inject binary uses bracketed-paste sequences that
Kimi's prompt_toolkit shell inserts into the buffer without auto-submitting
when idle.  Direct PTS write bypasses this and wakes the TUI reliably.

Status: PROVEN live 2026-04-13 (c88ab4c / 5086db4).  Direct PTS write wakes
        idle Kimi TUI; kimi-nova drained via mcp__c2c__poll_inbox and replied.

Usage (manual, from the repo root):
    python3 c2c_kimi_wake_daemon.py \\
        --terminal-pid <ghostty/tmux pid> \\
        --pts <pts number> \\
        [--session-id kimi-<user>-<host>] \\
        [--alias kimi-<user>-<host>]

Or start it automatically after `c2c setup kimi` — see docs/client-delivery.md.
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

WAKE_PROMPT_TEMPLATE = (
    "You have pending c2c direct messages. "
    "Please call mcp__c2c__poll_inbox right now (no arguments). "
    "For EACH message in the result, call mcp__c2c__send with "
    "from_alias='{alias}', to_alias=<the from_alias field of that message>, "
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


def default_alias() -> str:
    env = os.environ.get("C2C_MCP_AUTO_REGISTER_ALIAS", "").strip()
    if env:
        return env
    import socket
    return f"kimi-{os.environ.get('USER', 'user')}-{socket.gethostname().split('.')[0]}"


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


def pts_inject(
    pts: int,
    message: str,
    *,
    dry_run: bool,
) -> bool:
    """Write message directly to /dev/pts/<pts> — bypasses bracketed paste."""
    if dry_run:
        print(f"[kimi-wake] dry-run: would inject to /dev/pts/{pts}: {message[:80]}...")
        return True
    try:
        import c2c_pts_inject
        c2c_pts_inject.inject(pts, message)
        return True
    except Exception as exc:
        print(f"[kimi-wake] pts_inject error: {exc}", file=sys.stderr)
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
            # Watch parent directory for file creation/updates
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
    alias: str,
    terminal_pid: int,
    pts: int,
    broker_root: Path,
    interval: float,
    min_inject_gap: float,
    dry_run: bool,
    once: bool,
) -> None:
    inbox = inbox_path(broker_root, session_id)
    last_inject_time = 0.0
    wake_prompt = WAKE_PROMPT_TEMPLATE.format(alias=alias)

    print(f"[kimi-wake] watching {inbox} → /dev/pts/{pts} (terminal_pid={terminal_pid})")
    print(f"[kimi-wake] alias={alias} min_inject_gap={min_inject_gap}s interval={interval}s")

    while True:
        if inbox_has_messages(inbox):
            now = time.monotonic()
            gap = now - last_inject_time
            if gap >= min_inject_gap:
                print("[kimi-wake] inbox has messages, injecting wake-up")
                ok = pts_inject(pts, wake_prompt, dry_run=dry_run)
                if ok:
                    last_inject_time = now
            else:
                print(f"[kimi-wake] inbox has messages but injected {gap:.1f}s ago, waiting")

            if once:
                break
            time.sleep(min(interval, 5.0))
        else:
            if once:
                break
            if not watch_with_inotifywait(inbox, timeout=interval):
                time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PTY-wake daemon for Kimi Code inbox auto-delivery")
    parser.add_argument("--session-id", help="broker session id to watch (default: alias value)")
    parser.add_argument("--alias", default=None, help="Kimi agent alias (default: kimi-user-host)")
    parser.add_argument("--terminal-pid", type=int, required=True,
                        help="Terminal process pid (for logging; injection uses --pts directly)")
    parser.add_argument("--pts", type=int, required=True, help="pts slave number (writes to /dev/pts/<N>)")
    parser.add_argument("--broker-root", type=Path)
    parser.add_argument("--interval", type=float, default=10.0, help="fallback poll interval (seconds)")
    parser.add_argument("--min-inject-gap", type=float, default=15.0,
                        help="minimum seconds between PTY injections")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--once", action="store_true", help="inject once if inbox has messages and exit")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    alias = args.alias or default_alias()
    session_id = args.session_id or alias
    broker_root = args.broker_root or default_broker_root()

    run(
        session_id=session_id,
        alias=alias,
        terminal_pid=args.terminal_pid,
        pts=args.pts,
        broker_root=broker_root,
        interval=args.interval,
        min_inject_gap=args.min_inject_gap,
        dry_run=args.dry_run,
        once=args.once,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
