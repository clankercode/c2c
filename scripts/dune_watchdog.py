#!/usr/bin/env python3
"""Guard a build/test command with a timeout watchdog.

Usage:
    scripts/dune-watchdog.sh <timeout_secs> <cmd> [args...]

Environment:
    DUNE_WATCHDOG=0          Run the command directly without timeout logic.
    DUNE_WATCHDOG_TIMEOUT=N  Override the positional timeout value.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


def _usage() -> "NoReturn":
    print(
        "usage: scripts/dune-watchdog.sh <timeout_secs> <cmd> [args...]",
        file=sys.stderr,
    )
    raise SystemExit(2)


def _banner(timeout_s: float) -> str:
    timeout_display = int(timeout_s) if timeout_s.is_integer() else timeout_s
    return f"""==========================================================================
DUNE WATCHDOG: killed command after {timeout_display} seconds.

dune may hang due to deadlock, remote opam mirror issues, or resource
exhaustion. This watchdog fires automatically to prevent indefinite blocks.

To DISABLE the watchdog for this call:
  DUNE_WATCHDOG=0 just <recipe>

To change the timeout (in seconds):
  DUNE_WATCHDOG_TIMEOUT=120 just <recipe>
==========================================================================
"""


def _terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        pass
    try:
        proc.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        pass
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        _usage()

    raw_timeout = os.environ.get("DUNE_WATCHDOG_TIMEOUT", argv[1])
    try:
        timeout_s = float(raw_timeout)
    except ValueError:
        print(f"invalid watchdog timeout: {raw_timeout!r}", file=sys.stderr)
        return 2
    if timeout_s <= 0:
        print(f"watchdog timeout must be > 0, got {raw_timeout!r}", file=sys.stderr)
        return 2

    cmd = argv[2:]
    if not cmd:
        _usage()

    if os.environ.get("DUNE_WATCHDOG") == "0":
        completed = subprocess.run(cmd, check=False)
        return completed.returncode

    proc = subprocess.Popen(cmd, start_new_session=True)
    deadline = time.monotonic() + timeout_s

    while True:
        rc = proc.poll()
        if rc is not None:
            return rc
        if time.monotonic() >= deadline:
            _terminate_process_group(proc)
            print(_banner(timeout_s), file=sys.stderr, end="")
            return 124
        time.sleep(min(0.1, max(0.01, deadline - time.monotonic())))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
