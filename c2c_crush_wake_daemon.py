#!/usr/bin/env python3
"""Auto-delivery daemon: watches a Crush session inbox and PTY-wakes the TUI.

Same pattern as c2c_opencode_wake_daemon.py.  Crush (by Charmbracelet) is a
terminal-based CLI that accepts user prompts and calls MCP tools in each turn.
When a new c2c message arrives in the broker inbox, this daemon PTY-injects a
short wake prompt that tells the Crush agent to call mcp__c2c__poll_inbox.

Status: skeleton — structure is proven (OpenCode), Crush PTY injection path
        is not yet live-tested.  Will need terminal_pid and pts for the
        Crush TUI session (same as OpenCode).

Usage (manual, from the repo root):
    python3 c2c_crush_wake_daemon.py \\
        --terminal-pid <ghostty/tmux pid> \\
        --pts <pts number> \\
        [--session-id crush-<user>-<host>] \\
        [--alias crush-<user>-<host>]

Or start it automatically after `c2c setup crush` — see docs/client-delivery.md.
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
PTY_INJECT = Path("/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject")

WAKE_PROMPT_TEMPLATE = (
    "You have c2c messages waiting. "
    "Call mcp__c2c__poll_inbox and reply via mcp__c2c__send now."
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
    return f"crush-{os.environ.get('USER', 'user')}-{socket.gethostname().split('.')[0]}"


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
        print(f"[crush-wake] dry-run: would inject to terminal_pid={terminal_pid} pts={pts}: {message[:80]}...")
        return True
    if not PTY_INJECT.exists():
        print(f"[crush-wake] pty_inject not found: {PTY_INJECT}", file=sys.stderr)
        return False
    try:
        command = [str(PTY_INJECT), str(terminal_pid), str(pts), message]
        if submit_delay is not None:
            command.append(f"{submit_delay:g}")
        timeout = 5.0 + (submit_delay or 0.0)
        result = subprocess.run(command, timeout=timeout, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[crush-wake] pty_inject failed: {result.stderr}", file=sys.stderr)
            return False
        return True
    except Exception as exc:
        print(f"[crush-wake] pty_inject error: {exc}", file=sys.stderr)
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


def heartbeat_loop(
    terminal_pid: int,
    pts: int,
    alias: str,
    interval: float,
    dry_run: bool,
) -> None:
    msg = f"c2c heartbeat for {alias} — poll your inbox if idle."
    print(f"[crush-wake] heartbeat every {interval}s")
    while True:
        time.sleep(interval)
        pty_inject(terminal_pid, pts, msg, dry_run=dry_run, submit_delay=None)


def run(
    *,
    session_id: str,
    alias: str,
    terminal_pid: int,
    pts: int,
    broker_root: Path,
    interval: float,
    min_inject_gap: float,
    submit_delay: float | None,
    dry_run: bool,
    once: bool,
    heartbeat_interval: float | None,
) -> None:
    inbox = inbox_path(broker_root, session_id)
    last_inject_time = 0.0
    wake_prompt = WAKE_PROMPT_TEMPLATE.format(alias=alias)

    print(f"[crush-wake] watching {inbox} → PTY terminal_pid={terminal_pid} pts={pts}")
    print(f"[crush-wake] alias={alias} min_inject_gap={min_inject_gap}s interval={interval}s")

    if heartbeat_interval:
        import threading
        threading.Thread(
            target=heartbeat_loop,
            args=(terminal_pid, pts, alias, heartbeat_interval, dry_run),
            daemon=True,
        ).start()

    while True:
        if inbox_has_messages(inbox):
            now = time.monotonic()
            gap = now - last_inject_time
            if gap >= min_inject_gap:
                print("[crush-wake] inbox has messages, injecting wake-up")
                ok = pty_inject(
                    terminal_pid, pts, wake_prompt,
                    dry_run=dry_run, submit_delay=submit_delay,
                )
                if ok:
                    last_inject_time = now
            else:
                print(f"[crush-wake] inbox has messages but injected {gap:.1f}s ago, waiting")

            if once:
                break
            time.sleep(min(interval, 5.0))
        else:
            if once:
                break
            if not watch_with_inotifywait(inbox, timeout=interval):
                time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PTY-wake daemon for Crush inbox auto-delivery")
    parser.add_argument("--session-id", help="broker session id to watch (default: alias value)")
    parser.add_argument("--alias", default=None, help="Crush agent alias (default: crush-user-host)")
    parser.add_argument("--terminal-pid", type=int, required=True, help="PTY master pid")
    parser.add_argument("--pts", type=int, required=True, help="pts slave number")
    parser.add_argument("--broker-root", type=Path)
    parser.add_argument("--interval", type=float, default=10.0, help="fallback poll interval (seconds)")
    parser.add_argument("--min-inject-gap", type=float, default=15.0,
                        help="minimum seconds between PTY injections")
    parser.add_argument("--submit-delay", type=float, default=None,
                        help="seconds to wait between bracketed paste and Enter")
    parser.add_argument("--heartbeat-interval", type=float, default=None,
                        help="optional seconds between keepalive heartbeats")
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
        submit_delay=args.submit_delay,
        dry_run=args.dry_run,
        once=args.once,
        heartbeat_interval=args.heartbeat_interval,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
