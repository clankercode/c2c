#!/usr/bin/env python3
"""
Connect to the abstract Unix domain socket shared by Claude processes.
Abstract sockets on Linux use the pattern \x00 + name, but here we just have an inode.
"""

import socket
import struct

SOCKET_INODE = 531398


def connect_to_abstract_socket():
    """Try to connect to the abstract socket by inode."""
    # Linux abstract socket address format: \x00 followed by the path
    # But for sockets identified by inode in /proc/net/unix, we use the inode as the address
    # Format: \x00/proc/PID/fd/<fd> doesn't work directly

    # Try connecting using the inode as a path (some programs support this)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    # The address for an abstract socket is simply the string representation
    # We need to use the kernel's internal representation
    # Try: connect to @531398 (using @ for abstract)
    try:
        # This format uses @ prefix for abstract on some systems
        addr = f"@{SOCKET_INODE}"
        sock.connect(addr)
        print(f"Connected via {addr}")
        return sock
    except Exception as e1:
        print(f"@{SOCKET_INODE} failed: {e1}")

    try:
        # Try null-prefixed inode
        addr = f"\x00{SOCKET_INODE}"
        sock.close()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(addr)
        print(f"Connected via null-prefixed")
        return sock
    except Exception as e2:
        print(f"null-prefixed failed: {e2}")

    return None


def send_json_message(sock, msg_type, payload):
    """Try to send a JSON message in Claude's format."""
    import json

    msg = {"type": msg_type, "payload": payload}
    data = json.dumps(msg).encode("utf-8")
    try:
        sock.sendall(data)
        print(f"Sent: {data[:100]}")

        # Try to get response
        sock.settimeout(2.0)
        try:
            resp = sock.recv(4096)
            print(f"Received: {resp[:200]}")
        except socket.timeout:
            print("No response within 2s")
    except Exception as e:
        print(f"Send failed: {e}")


def probe_socket_info():
    """Get detailed info about the socket connections."""
    print("\n=== /proc/net/unix detail ===")
    with open("/proc/net/unix", "r") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 7 and parts[6] == str(SOCKET_INODE):
                print(f"Found: {line.strip()}")
                # Num connections is field 4
                num_conns = parts[4]
                print(f"Number of connections: {num_conns}")


if __name__ == "__main__":
    probe_socket_info()
    sock = connect_to_abstract_socket()
    if sock:
        send_json_message(sock, "ping", {"from": "investigator"})
        sock.close()
