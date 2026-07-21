#!/usr/bin/env python3
"""Direct PTY-slave writer. DEPRECATED.

Writes plain text directly to /dev/pts/<N>, followed by CR+LF.  This
is useful only when intentionally writing display output to a terminal. It is
not a reliable input injection path for interactive TUIs: keyboard input
arrives through the PTY master side, while writing to the slave can make text
appear without delivering it to the program's stdin.

DEPRECATED: c2c_deliver_inbox.py still imports this, but the PTY master
path via pty_inject/c2c_pty_inject.py is the preferred injection method.
This file is kept for diagnostics and will be removed once the last caller
is migrated.
"""
from __future__ import annotations

import os
import time
from pathlib import Path


def inject(
    pts_num: str | int,
    message: str,
    *,
    crlf: bool = True,
    char_delay: float | None = None,
) -> None:
    """Write *message* directly to /dev/pts/<pts_num>.

    Args:
        pts_num: PTS slave number (e.g., "0" or 0).
        message: Text to write to the terminal display side.
        crlf: If True, append ``\r\n`` after the message.
        char_delay: Seconds to sleep between each character.
    """
    pts_path = Path(f"/dev/pts/{pts_num}")
    if not pts_path.exists():
        raise RuntimeError(f"PTS device does not exist: {pts_path}")

    fd = os.open(str(pts_path), os.O_WRONLY | os.O_NOCTTY)
    try:
        if char_delay is not None and char_delay > 0:
            for ch in message:
                os.write(fd, ch.encode("utf-8"))
                time.sleep(char_delay)
        else:
            os.write(fd, message.encode("utf-8"))
        if crlf:
            os.write(fd, b"\r\n")
    finally:
        os.close(fd)
