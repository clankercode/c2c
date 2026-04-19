#!/usr/bin/env python3
"""Multi-part injection helper for Claude sessions.

Supports two injection methods:
1. PTY injection — for terminal emulator sessions (Ghostty, etc.) with ptmx master.
   Uses bracketed paste + Enter sequence via pty_inject helper.
2. history.jsonl injection — for SSH sessions or when PTY injection is unavailable.
   Appends a user message entry directly to the session transcript.

Protocol per part for PTY (from findings-pty.md):
  1. Write \\x1b[200~MSG\\x1b[201~ to PTY master fd
  2. Wait ~200 ms (handled by pty_inject)
  3. Write Enter \\r separately

Usage:
  c2c_inject_parts.py [--terminal-pid P --pts N | --claude-session ID | --pid N]
                      [--session-id SESSION_ID] [--transcript-path PATH]
                      [--parts PART [PART ...]] [--delay MS] [--json]

Each PART may be:
  - plain text: sent as-is
  - a special keycode: :enter, :esc, :ctrlc, :ctrlz, :up, :down, :left, :right, :tab, :backspace
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parent
PTY_INJECT = Path(
    os.environ.get(
        "C2C_PTY_INJECT",
        "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject",
    )
)

sys.path.insert(0, str(BASE))
from c2c_poker import resolve_claude_session, resolve_pid  # noqa: E402


def resolve_target(
    terminal_pid: int | None,
    pts: str | None,
    claude_session: str | None,
    pid: int | None,
) -> tuple[int, str, str | None, str | None]:
    """Resolve (terminal_pid, pts_num, session_id, transcript_path) from CLI args.

    Returns (terminal_pid, pts_num, session_id, transcript_path) where
    session_id and transcript_path may be None when not determinable.
    """
    if claude_session:
        terminal_pid, pts_num, transcript = resolve_claude_session(claude_session)
        # Extract session_id from the session data if available
        session_id = claude_session  # best effort
        return terminal_pid, pts_num, session_id, transcript
    if pid is not None:
        terminal_pid, pts_num, transcript = resolve_pid(pid)
        session_id = str(pid)  # best effort
        return terminal_pid, pts_num, session_id, transcript
    if terminal_pid is not None and pts is not None:
        return int(terminal_pid), str(pts), None, None
    raise RuntimeError("must specify one of: --claude-session, --pid, or --terminal-pid + --pts")


def inject_via_pty(terminal_pid: int, pts_num: str, payload: str, submit_delay: float) -> None:
    """Inject one part via pty_inject with the given submit_delay."""
    cmd = [str(PTY_INJECT), str(terminal_pid), pts_num, payload]
    if submit_delay is not None:
        cmd.append(f"{submit_delay:g}")
    subprocess.run(cmd, check=True, capture_output=True, text=True)


def inject_via_history(session_id: str, transcript_path: str, message: str) -> None:
    """Inject a message by appending a user entry to the session transcript JSONL."""
    entry = {
        "type": "user",
        "message": {
            "role": "user",
            "content": message,
        },
        "uuid": str(uuid.uuid4()),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sessionId": session_id,
    }
    with open(transcript_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def find_transcript_path(session_id: str, cwd: str | None = None) -> str | None:
    """Find the transcript path for a session ID.

    Searches in ~/.claude/projects/ for a file named <session_id>.jsonl.
    If cwd is provided, prioritizes the slug derived from cwd.
    """
    home = Path.home()
    projects_dir = home / ".claude" / "projects"
    if not projects_dir.is_dir():
        return None
    # Try to find by session_id
    direct = projects_dir / f"{session_id}.jsonl"
    if direct.exists():
        return str(direct)
    # Search all jsonl files for matching sessionId in content (slow path)
    for jsonl_file in projects_dir.glob("*.jsonl"):
        try:
            with open(jsonl_file) as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                        if entry.get("sessionId") == session_id:
                            return str(jsonl_file)
                    except json.JSONDecodeError:
                        continue
        except OSError:
            continue
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject sequential message parts into a Claude session PTY or history."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")
    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument(
        "--session-id",
        metavar="SESSION_ID",
        help="Session ID for history injection (auto-detected when possible).",
    )
    parser.add_argument(
        "--transcript-path",
        metavar="PATH",
        help="Path to session transcript JSONL for history injection.",
    )
    parser.add_argument(
        "--parts",
        nargs="+",
        required=True,
        metavar="PART",
        help="Message parts to inject sequentially.",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=500.0,
        metavar="MS",
        help="Delay between parts in milliseconds (default: 500).",
    )
    parser.add_argument(
        "--submit-delay",
        type=float,
        default=0.2,
        metavar="SECONDS",
        help="Delay between paste and Enter within each part (default: 0.2).",
    )
    parser.add_argument(
        "--method",
        choices=["auto", "pty", "history"],
        default="auto",
        help="Injection method: auto (try pty then history), pty, or history (default: auto).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be injected without actually injecting.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output machine-readable JSON.",
    )
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")

    # Combine parts into a single message
    message = "".join(args.parts)

    # Resolve target
    try:
        terminal_pid, pts_num, resolved_session_id, resolved_transcript = resolve_target(
            args.terminal_pid, args.pts, args.claude_session, args.pid
        )
    except RuntimeError as e:
        if args.json:
            print(json.dumps({"ok": False, "error": str(e)}))
            return 1
        raise

    # Use explicitly provided session_id / transcript, or fall back to resolved
    session_id = args.session_id or resolved_session_id
    transcript_path = args.transcript_path or resolved_transcript

    # If we have session_id but no transcript_path, try to find it
    if session_id and not transcript_path:
        transcript_path = find_transcript_path(session_id)

    if args.dry_run:
        print(f"[dry-run] message: {message!r}")
        print(f"[dry-run] method: {args.method}")
        print(f"[dry-run] terminal_pid: {terminal_pid}, pts: {pts_num}")
        print(f"[dry-run] session_id: {session_id}")
        print(f"[dry-run] transcript: {transcript_path}")
        if args.json:
            print(
                json.dumps(
                    {
                        "ok": True,
                        "dry_run": True,
                        "message": message,
                        "method": args.method,
                        "terminal_pid": terminal_pid,
                        "pts": pts_num,
                        "session_id": session_id,
                        "transcript_path": transcript_path,
                    }
                )
            )
        return 0

    method_used = None
    pty_error = None
    history_error = None

    if args.method in ("auto", "pty"):
        # Try PTY injection
        try:
            inject_via_pty(terminal_pid, pts_num, message, args.submit_delay)
            method_used = "pty"
        except (subprocess.CalledProcessError, OSError) as e:
            pty_error = str(e)
            if args.method == "pty":
                if args.json:
                    print(json.dumps({"ok": False, "method": "pty", "error": pty_error}))
                    return 1
                raise RuntimeError(f"PTY injection failed: {pty_error}")

    if method_used is None and args.method in ("auto", "history"):
        # Fall back to history injection
        if not session_id:
            history_error = "session_id not available (cannot fall back to history injection)"
        elif not transcript_path:
            history_error = f"transcript path not found for session {session_id}"
        else:
            try:
                inject_via_history(session_id, transcript_path, message)
                method_used = "history"
            except (OSError, IOError) as e:
                history_error = str(e)

    if method_used is None:
        # Both methods failed
        error_msg = (
            f"PTY injection failed: {pty_error}; "
            f"history injection failed: {history_error}"
        )
        if args.json:
            print(json.dumps({
                "ok": False,
                "pty_error": pty_error,
                "history_error": history_error,
                "error": error_msg,
            }))
            return 1
        raise RuntimeError(error_msg)

    if args.json:
        print(
            json.dumps(
                {
                    "ok": True,
                    "method": method_used,
                    "message": message,
                    "terminal_pid": terminal_pid,
                    "pts": pts_num,
                    "session_id": session_id,
                    "transcript_path": transcript_path,
                    "sent_at": time.time(),
                }
            )
        )
    else:
        print(f"injected ({method_used}): {message!r}")
        if session_id:
            print(f"  session: {session_id}")
        if transcript_path:
            print(f"  transcript: {transcript_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
