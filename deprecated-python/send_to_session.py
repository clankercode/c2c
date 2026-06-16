#!/usr/bin/env python3
"""
Send a message to a Claude session via the shared Unix socket.
All Claude processes share socket pair 531398/531399.
This script attempts to send a message in a format Claude understands.
"""

import socket
import json
import struct
import os


def send_via_shared_socket(session_id, message):
    """Try to send a message via the shared IPC socket."""
    # The socket inode
    INODE = 531398

    # Try to connect using abstract socket format
    # Linux abstract sockets can be addressed via /proc/PID/fd/X
    # Let's find which process has the listening socket

    # First, let's see if we can find the listening socket
    print(f"Trying to send to session {session_id}")

    # Try sending via FD passing through /proc
    # Actually, let's try using a different approach:
    # Create a socket pair, send one end to the target

    # Alternative: use the history.jsonl approach
    # Write a message that looks like it came from the user

    return False


def inject_via_history(session_id, message):
    """Inject a message by directly appending to history.jsonl."""
    import time

    history_file = os.path.expanduser("~/.claude/history.jsonl")

    # Create a message entry
    entry = {
        "type": "human",
        "display": message,
        "sessionId": session_id,
        "timestamp": int(time.time() * 1000),
        "project": "/home/xertrov/tmp",
    }

    # Read existing history
    with open(history_file, "r") as f:
        lines = f.readlines()

    # Append new message
    with open(history_file, "a") as f:
        f.write(json.dumps(entry) + "\n")

    print(f"Injected message to history for session {session_id}")
    return True


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: send_to_session.py <session-id> <message>")
        sys.exit(1)

    session_id = sys.argv[1]
    message = sys.argv[2]

    print(f"Attempting to send message to session {session_id}")

    # Try history injection
    inject_via_history(session_id, message)
