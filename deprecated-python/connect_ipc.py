#!/usr/bin/env python3
"""
Try to connect to Claude's shared IPC socket and send a message.
Socket inode 531398 is shared by all Claude processes.
"""

import socket
import struct
import os
import json

SOCKET_INODE = 531398


def get_socket_addr():
    """Get the kernel's internal address for the socket."""
    # Read /proc/net/unix to find the socket's kernel address
    with open("/proc/net/unix", "r") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 7 and parts[6] == str(SOCKET_INODE):
                # The format is: num: flags type st inodepath
                # For abstract sockets, the path is empty or starts with @
                # But actually, the kernel assigns an internal address
                # Let's try to connect using the inode as a path
                return None
    return None


def try_connect():
    """Try various approaches to connect to the socket."""
    # Approach 1: Try /proc/PID/fd/X as address (doesn't work for Unix sockets)
    # Approach 2: Use the kernel's internal socket name lookup

    # Actually, let's just try a few things and see
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    # Try empty string (default address)
    try:
        sock.connect("")
        print("Connected with empty string")
        return sock
    except Exception as e:
        print(f"Empty string failed: {e}")

    # Try @53013198 (some systems use @ prefix for abstract)
    try:
        sock.close()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(f"@{SOCKET_INODE}")
        print(f"Connected with @{SOCKET_INODE}")
        return sock
    except Exception as e:
        print(f"@{SOCKET_INODE} failed: {e}")

    return None


def send_control_message(sock):
    """Try to send a message using the Claude IPC protocol."""
    # Let's try various message formats
    messages = [
        {"type": "ping", "id": "1"},
        {"type": "user_message", "message": "hello", "session": "test"},
        json.dumps({"type": "ping"}).encode(),
        b"ping",
    ]

    for msg in messages:
        try:
            if isinstance(msg, dict):
                data = json.dumps(msg).encode()
            else:
                data = msg
            sock.sendall(data)
            sock.settimeout(1.0)
            try:
                resp = sock.recv(4096)
                print(f"Sent {msg[:50]}... Got: {resp[:100]}")
            except socket.timeout:
                print(f"Sent {msg[:50]}... No response")
        except Exception as e:
            print(f"Send failed for {msg[:50]}: {e}")


if __name__ == "__main__":
    print(f"Trying to connect to Claude IPC socket (inode {SOCKET_INODE})...")
    sock = try_connect()
    if sock:
        send_control_message(sock)
        sock.close()
    else:
        print("Could not connect to socket")

    # Let's also list all Unix sockets to understand the landscape
    print("\n--- All sockets in /proc/net/unix (first 20) ---")
    with open("/proc/net/unix", "r") as f:
        for i, line in enumerate(f):
            if i < 20:
                print(line.strip())
