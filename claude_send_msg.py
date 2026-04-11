#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


HOME = Path.home()
BASE = Path(__file__).resolve().parent
LISTER = BASE / "claude_list_sessions.py"
PTY_INJECT = Path("/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject")
ALLOWED_NAMES = {"C2C msg test", "C2C-test-agent2"}


def load_sessions():
    result = subprocess.run(
        [sys.executable, str(LISTER), "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def find_session(identifier: str, sessions: list[dict]):
    for session in sessions:
        if identifier in {
            session.get("session_id", ""),
            session.get("name", ""),
            str(session.get("pid", "")),
        }:
            return session
    return None


def inject(session: dict, message: str):
    tty = session.get("tty", "")
    if not tty.startswith("/dev/pts/"):
        raise RuntimeError("target session has no pts tty")
    pts_num = tty.rsplit("/", 1)[-1]
    terminal_pid = str(session.get("terminal_pid", ""))
    if not terminal_pid:
        raise RuntimeError("could not determine terminal pid")
    subprocess.run(
        [str(PTY_INJECT), terminal_pid, pts_num, message],
        check=True,
        capture_output=True,
        text=True,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Send a PTY-injected message to a running Claude session.",
        epilog=(
            "Examples:\n"
            "  claude-send-msg 'C2C-test-agent2' 'Hello there'\n"
            "  claude-send-msg 'C2C msg test' '<c2c-message>What topic should we discuss?</c2c-message>'"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("to")
    parser.add_argument("message", nargs="+")
    parser.add_argument("--allow-non-c2c", action="store_true")
    parser.add_argument("--tag", default="c2c")
    args = parser.parse_args()

    sessions = load_sessions()
    session = find_session(args.to, sessions)
    if not session:
        print(f"session not found: {args.to}", file=sys.stderr)
        sys.exit(1)

    if not args.allow_non_c2c and session.get("name") not in ALLOWED_NAMES:
        print(
            f"refusing to send to non-C2C session: {session.get('name')}",
            file=sys.stderr,
        )
        sys.exit(2)

    message = " ".join(args.message)

    if message.lstrip().startswith("<"):
        payload = message
    else:
        payload = f"<{args.tag}-message>\n{message}\n</{args.tag}-message>"
    inject(session, payload)
    print(
        json.dumps(
            {
                "ok": True,
                "to": session.get("name"),
                "session_id": session.get("session_id"),
                "pid": session.get("pid"),
                "sent_at": time.time(),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
