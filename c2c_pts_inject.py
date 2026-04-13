#!/usr/bin/env python3
"""Direct PTS write injection — alternative to pty_inject for clients that
don't handle bracketed paste well when idle (e.g., Kimi Code).

Writes plain text directly to /dev/pts/<N>, followed by CR+LF.  This
bypasses the terminal emulator's master-fd and avoids bracketed-paste
sequences that prompt_toolkit may treat as buffer insertions without
auto-submission.
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
        message: Text to inject.
        crlf: If True, append ``\r\n`` after the message.
        char_delay: Seconds to sleep between each character.  Use a small
            value (e.g., 0.001) if the target TUI needs keystroke-by-keystroke
            delivery rather than a bulk write.
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
