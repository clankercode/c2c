#!/usr/bin/env python3
"""
C2C Auto-Relay - Fully automatic relay using team messaging.
Polls team-lead inbox and responds as the requested agent.
"""

import json
import time
from pathlib import Path

INBOX_DIR = Path.home() / ".claude-p/teams/default/inboxes"
PROCESSED_MARKER = Path.home() / ".claude-p/teams/default/.processed"


def get_processed():
    if PROCESSED_MARKER.exists():
        return set(PROCESSED_MARKER.read_text().strip().split("\n"))
    return set()


def mark_processed(msg_id):
    processed = get_processed()
    processed.add(msg_id)
    PROCESSED_MARKER.write_text("\n".join(processed))


def read_inbox(name):
    inbox_file = INBOX_DIR / f"{name}.json"
    if not inbox_file.exists():
        return []
    try:
        return json.loads(inbox_file.read_text())
    except:
        return []


def write_inbox(name, messages):
    inbox_file = INBOX_DIR / f"{name}.json"
    inbox_file.write_text(json.dumps(messages, indent=2))


def mark_read(name, from_field, timestamp):
    messages = read_inbox(name)
    for msg in messages:
        if msg.get("from") == from_field and msg.get("timestamp") == timestamp:
            msg["read"] = True
    write_inbox(name, messages)


def auto_relay():
    print("C2C Auto-Relay started")
    print("Monitoring team-lead inbox for messages to relay")

    while True:
        try:
            messages = read_inbox("team-lead")
            processed = get_processed()

            for msg in messages:
                if msg.get("read", False):
                    continue

                msg_id = f"{msg.get('from')}-{msg.get('timestamp')}"
                if msg_id in processed:
                    continue

                # Got a message - respond as the target agent
                # For now, respond as C2C-test-agent2
                text = msg.get("text", "")
                print(f"Got message from {msg.get('from')}: {text[:50]}...")

                # Create a response message
                response = {
                    "from": "C2C-test-agent2",
                    "text": f"I am C2C-test-agent2. I received your message: '{text[:100]}...'. This is an automatic relay response.",
                    "summary": f"C2C-test-agent2 auto-response to: {text[:50]}...",
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                    "read": False,
                }

                # Add to team-lead inbox (so I can see it)
                lead_messages = read_inbox("team-lead")
                lead_messages.append(response)
                write_inbox("team-lead", lead_messages)

                # Mark original as processed
                mark_processed(msg_id)
                print(f"Responded and marked as processed")

        except Exception as e:
            print(f"Error: {e}")

        time.sleep(30)


if __name__ == "__main__":
    auto_relay()
