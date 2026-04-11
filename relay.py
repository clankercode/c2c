#!/usr/bin/env python3
"""
C2C message relay - polls inbox files and delivers messages to sessions.
"""

import json
import os
import time
from pathlib import Path

INBOX_DIR = Path.home() / ".claude-p/teams/default/inboxes"
SESSION_DIR = Path.home() / ".claude-p/sessions"


def get_session_pts(session_name):
    """Find the TTY/pts for a session by name."""
    for session_file in SESSION_DIR.glob("*.json"):
        try:
            data = json.loads(session_file.read_text())
            if data.get("name") == session_name:
                pid = data.get("pid")
                if pid:
                    pts_file = f"/proc/{pid}/fd/1"
                    try:
                        link = os.readlink(pts_file)
                        if "/dev/pts/" in link:
                            return link
                    except:
                        pass
        except:
            pass
    return None


def read_inbox(session_name):
    """Read unread messages from a session's inbox."""
    inbox_file = INBOX_DIR / f"{session_name}.json"
    if not inbox_file.exists():
        return []

    try:
        messages = json.loads(inbox_file.read_text())
        return [m for m in messages if not m.get("read", False)]
    except:
        return []


def mark_read(session_name, from_field, timestamp):
    """Mark a message as read."""
    inbox_file = INBOX_DIR / f"{session_name}.json"
    if not inbox_file.exists():
        return

    try:
        messages = json.loads(inbox_file.read_text())
        for msg in messages:
            if msg.get("from") == from_field and msg.get("timestamp") == timestamp:
                msg["read"] = True
        inbox_file.write_text(json.dumps(messages, indent=2))
    except:
        pass


def deliver_via_pts(pts, message):
    """Deliver a message to a session via its TTY."""
    try:
        with open(pts, "w") as f:
            f.write(f"\n=== Message from {message['from']} ===\n")
            f.write(f"{message['text']}\n")
            f.write("=== End ===\n")
        return True
    except Exception as e:
        print(f"Failed to write to {pts}: {e}")
        return False


def relay_messages():
    """Poll inboxes and relay messages to sessions."""
    print("C2C Message Relay Started")
    print(f"Monitoring: {INBOX_DIR}")

    # Track which messages we've already delivered
    delivered = set()

    while True:
        for inbox_file in INBOX_DIR.glob("*.json"):
            session_name = inbox_file.stem
            pts = get_session_pts(session_name)

            if pts:
                messages = read_inbox(session_name)
                for msg in messages:
                    msg_key = (msg.get("from"), msg.get("timestamp"))
                    if msg_key not in delivered:
                        print(
                            f"Relaying to {session_name} ({pts}): {msg.get('text', '')[:50]}..."
                        )
                        if deliver_via_pts(pts, msg):
                            delivered.add(msg_key)
                            mark_read(
                                session_name, msg.get("from"), msg.get("timestamp")
                            )

        time.sleep(1)


if __name__ == "__main__":
    relay_messages()
