#!/usr/bin/env python3
"""
C2C File-Based Relay
Watches a shared file and delivers messages to Claude sessions via PTY.
"""

import json
import time
import os
import sys
from pathlib import Path

MSG_FILE = Path.home() / "tmp/c2c/messages.jsonl"


def ensure_dir():
    MSG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not MSG_FILE.exists():
        MSG_FILE.write_text("")


def read_messages():
    """Read all messages from the file."""
    try:
        lines = MSG_FILE.read_text().strip().split("\n")
        return [json.loads(l) for l in lines if l.strip()]
    except:
        return []


def write_messages(messages):
    """Write messages back to file."""
    MSG_FILE.write_text("\n".join(json.dumps(m) for m in messages) + "\n")


def get_session_pts(session_name):
    """Find PTY for a session by name."""
    session_dir = Path.home() / ".claude-p/sessions"
    for sf in session_dir.glob("*.json"):
        try:
            data = json.loads(sf.read_text())
            if data.get("name") == session_name:
                pid = data.get("pid")
                if pid:
                    pts = f"/proc/{pid}/fd/1"
                    try:
                        link = os.readlink(pts)
                        if "/dev/pts/" in link:
                            return link
                    except:
                        pass
        except:
            pass
    return None


def send_via_pty(pts, message):
    """Send message via PTY using bracketed paste."""
    if not pts:
        return False
    try:
        bracketed = f"\x1b[200~{message}\r\x1b[201~"
        with open(pts, "wb") as f:
            f.write(bracketed.encode())
        return True
    except Exception as e:
        print(f"PTY write failed: {e}")
        return False


def relay_loop():
    ensure_dir()
    print(f"C2C Relay started. Watching {MSG_FILE}")
    print("Format: {'from': 'name', 'to': 'name', 'msg': 'text'}")

    # Track processed messages
    processed = set()

    while True:
        messages = read_messages()
        for msg in messages:
            msg_id = f"{msg.get('from')}-{msg.get('msg', '')[:50]}"
            if msg_id in processed:
                continue

            to_name = msg.get("to")
            content = msg.get("msg", "")

            if to_name == "C2C-test-agent2":
                pts = get_session_pts("C2C-test-agent2")
                if pts:
                    print(f"Delivering to C2C-test-agent2 via {pts}: {content[:50]}...")
                    send_via_pty(pts, content)
                    processed.add(msg_id)
                    # Remove from file
                    messages = [
                        m
                        for m in messages
                        if f"{m.get('from')}-{m.get('msg', '')[:50]}" != msg_id
                    ]
                    write_messages(messages)

        time.sleep(2)


if __name__ == "__main__":
    relay_loop()
