#!/usr/bin/env python3
"""
Investigate the Unix domain socket IPC mechanism between Claude sessions.
Socket 531398/531399 is shared by all claude processes.
"""

import socket
import struct
import os

# The socket inode from the shared socket
SOCKET_INODE = 531398


def find_socket_path():
    """Find the socket file for the shared Claude IPC."""
    # Check /proc/net/unix for the socket
    with open("/proc/net/unix", "r") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 7:
                inode = parts[6]
                if inode == str(SOCKET_INODE):
                    # Found it - the path is in the last column
                    path = parts[-1]
                    print(f"Found socket at: {path}")
                    return path
    return None


def connect_and_probe(path):
    """Try to connect to the socket and see what happens."""
    if not path or path == "[]":
        print("Socket has no path (abstract namespace)")
        # Try to find it in /proc/PID/fd
        return None

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
        print(f"Connected to {path}")

        # Try to receive any greeting/handshake
        sock.settimeout(1.0)
        try:
            data = sock.recv(4096)
            if data:
                print(f"Received: {data[:200]}")
        except socket.timeout:
            print("No data received on connect")

        return sock
    except Exception as e:
        print(f"Connection failed: {e}")
        return None


if __name__ == "__main__":
    path = find_socket_path()
    print(f"Socket path: {path}")

    # Also list all Unix sockets to understand the landscape
    print("\n--- All Claude-related sockets in /proc/net/unix ---")
    with open("/proc/net/unix", "r") as f:
        for line in f:
            if "claude" in line.lower() or "531398" in line:
                print(line.strip())
