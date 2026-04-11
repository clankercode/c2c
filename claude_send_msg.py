#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from xml.sax.saxutils import quoteattr


HOME = Path.home()
BASE = Path(__file__).resolve().parent
LISTER = BASE / "claude_list_sessions.py"
PTY_INJECT = Path("/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject")
ALLOWED_NAMES = {"C2C msg test", "C2C-test-agent2"}


def load_sessions():
    result = subprocess.run(
        [sys.executable, str(LISTER), "--json", "--with-terminal-owner"],
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


def session_has_terminal_owner(session: dict) -> bool:
    return bool(str(session.get("terminal_pid", "")).strip())


def ensure_sendable_session(session: dict) -> dict:
    if session_has_terminal_owner(session):
        return session

    identifier = session.get("session_id") or str(session.get("pid", ""))
    if not identifier:
        return session

    resolved = find_session(identifier, load_sessions())
    if resolved is None:
        return session
    return resolved


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


def render_payload(
    message: str,
    event: str = "message",
    sender_name: str = "c2c-send",
    sender_alias: str = "",
) -> str:
    if message.lstrip().startswith("<"):
        return message

    attributes = [
        f"event={quoteattr(event)}",
        f"from={quoteattr(sender_name)}",
    ]
    if sender_alias:
        attributes.append(f"alias={quoteattr(sender_alias)}")
    return f"<c2c {' '.join(attributes)}>\n{message}\n</c2c>"


def build_send_result(session: dict) -> dict:
    return {
        "ok": True,
        "to": session.get("name"),
        "session_id": session.get("session_id"),
        "pid": session.get("pid"),
        "sent_at": time.time(),
    }


def use_send_message_fixture() -> bool:
    return os.environ.get("C2C_SEND_MESSAGE_FIXTURE") == "1"


def send_message_to_session(
    session: dict,
    message: str,
    event: str = "message",
    sender_name: str = "c2c-send",
    sender_alias: str = "",
) -> dict:
    session = ensure_sendable_session(session)
    if use_send_message_fixture():
        return build_send_result(session)
    inject(
        session,
        render_payload(
            message,
            event=event,
            sender_name=sender_name,
            sender_alias=sender_alias,
        ),
    )
    return build_send_result(session)


def main():
    parser = argparse.ArgumentParser(
        description="Send a PTY-injected message to a running Claude session.",
        epilog=(
            "Examples:\n"
            "  claude-send-msg 'C2C-test-agent2' 'Hello there'\n"
            '  claude-send-msg \'C2C msg test\' \'<c2c event="message" from="agent-one" alias="storm-herald">What topic should we discuss?</c2c>\''
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("to")
    parser.add_argument("message", nargs="+")
    parser.add_argument("--allow-non-c2c", action="store_true")
    parser.add_argument("--tag", dest="event", default="message")
    parser.add_argument("--event", default=None)
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
    event = args.event or args.tag
    print(json.dumps(send_message_to_session(session, message, event=event), indent=2))


if __name__ == "__main__":
    main()
