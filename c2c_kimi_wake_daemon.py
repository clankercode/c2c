#!/usr/bin/env python3
"""Auto-delivery daemon: watches a Kimi Code session inbox and PTY-wakes the TUI.

Same pattern as c2c_opencode_wake_daemon.py.  Kimi Code is a terminal-based
CLI that accepts user prompts and calls MCP tools in each turn.  When a new
c2c message arrives in the broker inbox, this daemon PTY-injects a short wake
prompt that tells the Kimi agent to call mcp__c2c__poll_inbox.

Status: skeleton — structure is proven (OpenCode), Kimi PTY injection path
        is not yet live-tested.  Will need terminal_pid and pts for the
        Kimi TUI session (same as OpenCode).

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
PTY_INJECT = Path("/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject")

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


def pty_inject(
    terminal_pid: int,
    pts: int,
    message: str,
    *,
    dry_run: bool,
    submit_delay: float | None,
) -> bool:
    if dry_run:
        print(f"[kimi-wake] dry-run: would inject to terminal_pid={terminal_pid} pts={pts}: {message[:80]}...")
        return True
    if not PTY_INJECT.exists():
        print(f"[kimi-wake] pty_inject not found: {PTY_INJECT}", file=sys.stderr)
        return False
    try:
        command = [str(PTY_INJECT), str(terminal_pid), str(pts), message]
        if submit_delay is not None:
            command.append(f"{submit_delay:g}")
        timeout = 5.0 + (submit_delay or 0.0)
        result = subprocess.run(command, timeout=timeout, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[kimi-wake] pty_inject failed: {result.stderr}", file=sys.stderr)
            return False
        return True
    except Exception as exc:
        print(f"[kimi-wake] pty_inject error: {exc}", file=sys.stderr)
        return False


def watch_with_inotifywait(inbox: Path) -> None:
    """Block until inbox file is written (up to 60s)."""
    try:
        subprocess.run(
            ["inotifywait", "-e", "close_write", str(inbox)],
            timeout=60.0,
            capture_output=True,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


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
) -> None:
    inbox = inbox_path(broker_root, session_id)
    last_inject_time = 0.0
    wake_prompt = WAKE_PROMPT_TEMPLATE.format(alias=alias)

    print(f"[kimi-wake] watching {inbox} → PTY terminal_pid={terminal_pid} pts={pts}")
    print(f"[kimi-wake] alias={alias} min_inject_gap={min_inject_gap}s interval={interval}s")

    while True:
        if inbox_has_messages(inbox):
            now = time.monotonic()
            gap = now - last_inject_time
            if gap >= min_inject_gap:
                print("[kimi-wake] inbox has messages, injecting wake-up")
                ok = pty_inject(
                    terminal_pid, pts, wake_prompt,
                    dry_run=dry_run, submit_delay=submit_delay,
                )
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
            watch_with_inotifywait(inbox)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PTY-wake daemon for Kimi Code inbox auto-delivery")
    parser.add_argument("--session-id", help="broker session id to watch (default: alias value)")
    parser.add_argument("--alias", default=None, help="Kimi agent alias (default: kimi-user-host)")
    parser.add_argument("--terminal-pid", type=int, required=True, help="PTY master pid")
    parser.add_argument("--pts", type=int, required=True, help="pts slave number")
    parser.add_argument("--broker-root", type=Path)
    parser.add_argument("--interval", type=float, default=10.0, help="fallback poll interval (seconds)")
    parser.add_argument("--min-inject-gap", type=float, default=15.0,
                        help="minimum seconds between PTY injections")
    parser.add_argument("--submit-delay", type=float, default=None,
                        help="seconds to wait between bracketed paste and Enter")
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
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
