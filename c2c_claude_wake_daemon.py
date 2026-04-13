#!/usr/bin/env python3
"""Auto-delivery daemon: watches a Claude Code session inbox and PTY-wakes it.

When new broker-native DMs arrive in the session inbox, this daemon injects
a minimal wake prompt that causes Claude Code to call mcp__c2c__poll_inbox.
Messages travel broker-native (not PTY), so Claude reads them with full
broker metadata intact via the MCP tool path.

This addresses the gap where Claude Code receives DMs only via the PostToolUse
hook (which only fires when Claude is actively running tools) or manual polling.
The wake daemon bridges the gap for idle Claude Code sessions.

Usage:
    python3 c2c_claude_wake_daemon.py [options]

    --claude-session NAME_OR_ID  Claude Code session name/id (uses claude_list_sessions.py)
    --pid N                      Claude Code process pid (auto-discovers PTY)
    --terminal-pid P --pts N     Explicit PTY coordinates
    --session-id S               Broker session id to watch (default: from registry)
    --broker-root DIR            Broker directory (default: auto-detected)
    --min-inject-gap N           Minimum seconds between PTY injections (default: 15)
    --interval N                 Poll fallback interval in seconds (default: 30)
    --dry-run                    Print what would be injected without injecting
    --once                       Check once and exit
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
PTY_INJECT = Path(
    os.environ.get(
        "C2C_PTY_INJECT",
        "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject",
    )
)

WAKE_PROMPT = (
    "c2c wake: you have pending broker-native DMs. "
    "Call mcp__c2c__poll_inbox right now (no arguments needed). "
    "This is a c2c auto-delivery notification — message content is in the broker, "
    "not in this wake signal."
)


def default_broker_root() -> Path:
    env = os.environ.get("C2C_MCP_BROKER_ROOT", "").strip()
    if env:
        return Path(env)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, cwd=ROOT,
        )
        if result.returncode == 0:
            git_dir = Path(result.stdout.strip())
            if not git_dir.is_absolute():
                git_dir = (ROOT / git_dir).resolve()
            return git_dir / "c2c" / "mcp"
    except Exception:
        pass
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


def find_session_id_from_registry(broker_root: Path, pid: int | None = None) -> str | None:
    """Try to find the session_id for the current or a given PID from broker registry."""
    registry_py = ROOT / "c2c_registry.py"
    if not registry_py.exists():
        return None
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("c2c_registry", registry_py)
        reg = importlib.util.load_from_spec(spec)  # type: ignore
        spec.loader.exec_module(reg)  # type: ignore
        regs = reg.load_broker_registrations(broker_root)
        for r in regs:
            if pid and r.get("pid") == pid:
                return str(r["session_id"])
    except Exception:
        pass
    # Fallback: look for C2C_MCP_SESSION_ID in env
    env_sid = os.environ.get("C2C_MCP_SESSION_ID", "").strip()
    if env_sid:
        return env_sid
    return None


def resolve_target(
    args: argparse.Namespace,
) -> tuple[int, str]:
    """Resolve (terminal_pid, pts_num) from CLI args."""
    sys.path.insert(0, str(ROOT))
    from claude_list_sessions import extract_pts, find_terminal_owner, readlink  # noqa: E402

    if args.terminal_pid and args.pts:
        return int(args.terminal_pid), str(args.pts)

    if args.pid:
        pid = int(args.pid)
        pts_num = None
        for fd in ("0", "1", "2"):
            pts_num = extract_pts(readlink(f"/proc/{pid}/fd/{fd}"))
            if pts_num:
                break
        if not pts_num:
            raise RuntimeError(f"pid {pid} has no /dev/pts/* on fds 0/1/2")
        owner = find_terminal_owner(pts_num, session_pid=pid)
        terminal_pid = owner[0] if owner else None
        if not terminal_pid:
            raise RuntimeError(f"no terminal owner for pid {pid} pts {pts_num}")
        return int(terminal_pid), pts_num

    if args.claude_session:
        lister = ROOT / "claude_list_sessions.py"
        result = subprocess.run(
            [sys.executable, str(lister), "--json", "--with-terminal-owner"],
            check=True, capture_output=True, text=True,
        )
        sessions = json.loads(result.stdout)
        ident = args.claude_session
        session = next(
            (s for s in sessions if ident in {
                s.get("session_id", ""), s.get("name", ""), str(s.get("pid", ""))
            }),
            None,
        )
        if not session:
            raise RuntimeError(f"claude session not found: {ident!r}")
        pts_num = extract_pts(session.get("tty", ""))
        terminal_pid = session.get("terminal_pid")
        if not terminal_pid or not pts_num:
            raise RuntimeError(f"session {ident!r} has no terminal owner")
        return int(terminal_pid), pts_num

    raise RuntimeError(
        "Must specify one of: --claude-session, --pid, or --terminal-pid + --pts"
    )


def do_inject(terminal_pid: int, pts: str, message: str, *, dry_run: bool) -> bool:
    if dry_run:
        print(f"[dry-run] would inject to terminal_pid={terminal_pid} pts={pts}:")
        print(f"  {message[:120]}...")
        return True
    if not PTY_INJECT.exists():
        print(f"[warn] pty_inject not found at {PTY_INJECT}", file=sys.stderr)
        return False
    try:
        result = subprocess.run(
            [str(PTY_INJECT), str(terminal_pid), str(pts), message],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            print(f"[warn] pty_inject failed: {result.stderr[:200]}", file=sys.stderr)
            return False
        return True
    except Exception as exc:
        print(f"[warn] pty_inject error: {exc}", file=sys.stderr)
        return False


def watch_with_inotifywait(inbox: Path, timeout: int = 30) -> bool:
    """Wait up to timeout seconds for inbox modification. Returns True if event."""
    try:
        result = subprocess.run(
            ["inotifywait", "-e", "close_write", "-t", str(timeout),
             "--quiet", "--format", "%e", str(inbox)],
            capture_output=True, text=True, timeout=timeout + 5,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def run_once(
    terminal_pid: int,
    pts: str,
    inbox: Path,
    *,
    dry_run: bool,
) -> bool:
    """Check inbox once; inject if non-empty. Returns True if injected."""
    if inbox_has_messages(inbox):
        return do_inject(terminal_pid, pts, WAKE_PROMPT, dry_run=dry_run)
    return False


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="c2c Claude Code wake daemon")
    target = p.add_mutually_exclusive_group()
    target.add_argument("--claude-session", metavar="NAME_OR_ID",
                        help="Claude Code session name or session_id")
    target.add_argument("--pid", type=int, metavar="N",
                        help="Claude Code process pid")
    p.add_argument("--terminal-pid", type=int, metavar="P")
    p.add_argument("--pts", metavar="N")
    p.add_argument("--session-id", metavar="S",
                   help="Broker session ID to watch (default: C2C_MCP_SESSION_ID or auto)")
    p.add_argument("--broker-root", metavar="DIR")
    p.add_argument("--min-inject-gap", type=float, default=15.0, metavar="N")
    p.add_argument("--interval", type=float, default=30.0, metavar="N")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--once", action="store_true")
    args = p.parse_args(argv)

    broker_root = Path(args.broker_root) if args.broker_root else default_broker_root()
    session_id = args.session_id or os.environ.get("C2C_MCP_SESSION_ID", "").strip()
    if not session_id:
        pid_for_lookup = args.pid
        session_id = find_session_id_from_registry(broker_root, pid_for_lookup)
    if not session_id:
        print("ERROR: could not determine session_id. Pass --session-id.", file=sys.stderr)
        return 2

    try:
        terminal_pid, pts = resolve_target(args)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    inbox = inbox_path(broker_root, session_id)
    print(
        f"[c2c-claude-wake] watching {inbox.name} "
        f"for session {session_id!r} "
        f"→ terminal_pid={terminal_pid} pts={pts}",
        flush=True,
    )

    if args.once:
        injected = run_once(terminal_pid, pts, inbox, dry_run=args.dry_run)
        print(f"[c2c-claude-wake] once: {'injected' if injected else 'nothing to inject'}")
        return 0

    last_inject = 0.0
    while True:
        # Try inotifywait first for efficiency; fall back to polling.
        if inbox.exists():
            watch_with_inotifywait(inbox, timeout=int(args.interval))
        else:
            time.sleep(args.interval)

        if inbox_has_messages(inbox):
            now = time.time()
            if now - last_inject >= args.min_inject_gap:
                injected = do_inject(terminal_pid, pts, WAKE_PROMPT, dry_run=args.dry_run)
                if injected:
                    last_inject = now
                    print(f"[c2c-claude-wake] injected wake at {time.strftime('%H:%M:%S')}", flush=True)
            else:
                gap = args.min_inject_gap - (now - last_inject)
                print(f"[c2c-claude-wake] inbox has messages but min_inject_gap not met ({gap:.1f}s left)", flush=True)


if __name__ == "__main__":
    sys.exit(main())
