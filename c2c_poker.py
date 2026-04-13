#!/usr/bin/env python3
"""Generic PTY poker — inject a heartbeat (or arbitrary message) into a TTY.

Keeps interactive TUI clients (Claude Code, OpenCode, Codex, plain shells)
awake by periodically posting a short message via `pty_inject`. Usable as a
foreground loop or backgrounded with `nohup ... &`.

Target resolution (pick one):

  --claude-session NAME_OR_ID   Use claude_list_sessions.py (Claude-only).
  --pid N                       Any interactive client. Reads the pts from
                                /proc/N/fd/0 and walks the parent chain (and
                                then all of /proc) to find the terminal owner.
  --terminal-pid P --pts N      Explicit coordinates — no resolution.

Example (start a 10-minute heartbeat on your own client, backgrounded):

  nohup python3 c2c_poker.py --pid $PPID --interval 600 \\
      --from my-agent --alias storm-beacon >/tmp/c2c-poker.log 2>&1 &
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from xml.sax.saxutils import quoteattr

BASE = Path(__file__).resolve().parent
PTY_INJECT = Path(
    os.environ.get(
        "C2C_PTY_INJECT",
        "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject",
    )
)

sys.path.insert(0, str(BASE))
from claude_list_sessions import (  # noqa: E402
    extract_pts,
    find_terminal_owner,
    readlink,
)

DEFAULT_INTERVAL = 600
DEFAULT_MESSAGE = (
    "Session heartbeat. Poll your C2C inbox now and handle any messages. "
    "If you need orientation, read tmp_status.txt and tmp_collab_lock.md. "
    "Empty inbox is not a stop signal: pick the highest-leverage unblocked "
    "task, respect active locks, coordinate before overlapping edits, and "
    "continue current work."
)


def list_claude_sessions() -> list[dict]:
    lister = BASE / "claude_list_sessions.py"
    result = subprocess.run(
        [sys.executable, str(lister), "--json", "--with-terminal-owner"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def find_claude_session(identifier: str) -> dict:
    for session in list_claude_sessions():
        if identifier in {
            session.get("session_id", ""),
            session.get("name", ""),
            str(session.get("pid", "")),
        }:
            return session
    raise RuntimeError(f"claude session not found: {identifier!r}")


def session_target(session: dict, identifier: str) -> tuple[int, str, str | None]:
    terminal_pid = session.get("terminal_pid") or ""
    pts_num = extract_pts(session.get("tty", ""))
    if not terminal_pid or not pts_num:
        raise RuntimeError(f"claude session {identifier!r} has no terminal owner")
    return int(terminal_pid), pts_num, session.get("transcript")


def resolve_claude_session(identifier: str) -> tuple[int, str, str | None]:
    return session_target(find_claude_session(identifier), identifier)


def resolve_pid(pid: int) -> tuple[int, str, str | None]:
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
        raise RuntimeError(f"no terminal owner found for pid {pid} pts {pts_num}")
    # Best-effort: match pid back to a Claude session to discover its transcript.
    transcript: str | None = None
    try:
        for session in list_claude_sessions():
            if session.get("pid") == pid:
                transcript = session.get("transcript")
                break
    except Exception:
        transcript = None
    return int(terminal_pid), pts_num, transcript


def transcript_is_idle(transcript: str | None, min_idle_seconds: float) -> bool:
    """Return True if the session appears idle — no transcript writes within the window.

    Best-effort only: Claude writes to the transcript file for both user and
    assistant turns, so a recently-modified file means a turn is in-flight or
    just finished. A stale file means the session is likely idle. Falls back to
    True (send) when we can't check.
    """
    if not transcript:
        return True
    try:
        mtime = os.path.getmtime(transcript)
    except OSError:
        return True
    return (time.time() - mtime) >= min_idle_seconds


def render_payload(
    message: str,
    event: str,
    sender: str,
    alias: str,
    raw: bool,
    *,
    source: str = "pty",
    source_tool: str = "c2c_poker",
) -> str:
    if raw or message.lstrip().startswith("<"):
        return message
    attrs = [f"event={quoteattr(event)}", f"from={quoteattr(sender)}"]
    if alias:
        attrs.append(f"alias={quoteattr(alias)}")
    if source:
        attrs.append(f"source={quoteattr(source)}")
    if source_tool:
        attrs.append(f"source_tool={quoteattr(source_tool)}")
    return f"<c2c {' '.join(attrs)}>\n{message}\n</c2c>"


def current_send_date() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S %Z")


def message_with_send_date(message: str) -> str:
    return f"{message}\n\nSent at: {current_send_date()}"


def pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def inject(terminal_pid: int, pts_num: str, payload: str) -> None:
    subprocess.run(
        [str(PTY_INJECT), str(terminal_pid), str(pts_num), payload],
        check=True,
        capture_output=True,
        text=True,
    )


def write_pidfile(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{os.getpid()}\n")


def log(msg: str) -> None:
    print(f"[c2c-poker {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Periodically inject a heartbeat into a TTY via pty_inject.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--claude-session", metavar="NAME_OR_ID")
    target.add_argument("--pid", type=int, metavar="PID")
    target.add_argument("--terminal-pid", type=int, metavar="PID")

    parser.add_argument("--pts", metavar="N", help="required with --terminal-pid")
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL)
    parser.add_argument("--message", default=DEFAULT_MESSAGE)
    parser.add_argument("--event", default="heartbeat")
    parser.add_argument("--from", dest="sender", default="c2c-poker")
    parser.add_argument("--alias", default="")
    parser.add_argument("--raw", action="store_true", help="don't wrap in <c2c>")
    parser.add_argument("--once", action="store_true", help="send one message and exit")
    parser.add_argument(
        "--initial-delay",
        type=float,
        default=0.0,
        help="seconds to wait before the first injection",
    )
    parser.add_argument("--pidfile", type=Path, default=None)
    parser.add_argument(
        "--only-if-idle-for",
        type=float,
        default=0.0,
        metavar="SECONDS",
        help="best-effort: only inject if the target session's transcript has"
        " been idle for at least this many seconds (requires a Claude session"
        " resolution path; no-op for raw --terminal-pid)",
    )
    args = parser.parse_args()

    if args.terminal_pid is not None and not args.pts:
        parser.error("--terminal-pid requires --pts")

    transcript: str | None = None
    watched_pid: int | None = None
    if args.claude_session:
        session = find_claude_session(args.claude_session)
        terminal_pid, pts_num, transcript = session_target(session, args.claude_session)
        watched_pid = int(session["pid"]) if session.get("pid") is not None else None
    elif args.pid is not None:
        watched_pid = args.pid
        terminal_pid, pts_num, transcript = resolve_pid(args.pid)
    else:
        terminal_pid, pts_num = args.terminal_pid, args.pts

    if args.pidfile:
        write_pidfile(args.pidfile)

    log(f"target pid={terminal_pid} pts={pts_num} interval={args.interval}s")

    stop = False

    def handle_signal(signum, _frame):
        nonlocal stop
        stop = True
        log(f"caught signal {signum}; exiting after current cycle")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    if args.initial_delay > 0:
        time.sleep(args.initial_delay)

    def watched_pid_has_exited() -> bool:
        if watched_pid is None:
            return False
        if pid_is_alive(watched_pid):
            return False
        log(f"watched pid {watched_pid} exited; stopping")
        return True

    while not stop:
        if watched_pid_has_exited():
            return 0
        if args.only_if_idle_for > 0 and not transcript_is_idle(
            transcript, args.only_if_idle_for
        ):
            log(f"skip: transcript active within {args.only_if_idle_for:.0f}s")
            if args.once:
                return 0
        else:
            payload = render_payload(
                message_with_send_date(args.message),
                args.event,
                args.sender,
                args.alias,
                args.raw,
            )
            try:
                inject(terminal_pid, pts_num, payload)
                log("injected")
            except subprocess.CalledProcessError as err:
                log(f"inject failed: rc={err.returncode} stderr={err.stderr.strip()!r}")
                return 1
            if args.once:
                return 0
        # sleep in short chunks so signal handling is responsive
        end = time.monotonic() + args.interval
        while not stop and time.monotonic() < end:
            if watched_pid_has_exited():
                return 0
            time.sleep(min(1.0, end - time.monotonic()))

    return 0


if __name__ == "__main__":
    sys.exit(main())
