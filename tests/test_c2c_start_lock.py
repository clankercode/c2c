"""
Integration tests for `c2c start` instance lock.

Two concurrent `c2c start opencode -n X` calls must not both succeed.
The second must fail immediately with a FATAL message.

Uses POSIX advisory lockf (via Python fcntl) held in a child process to
simulate an already-running instance, then asserts `c2c start` exits 1
with the expected FATAL message without touching real OpenCode.

Run with: C2C_TEST_INSTANCE_LOCK=1 pytest tests/test_c2c_start_lock.py -v
"""
from __future__ import annotations

import fcntl
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    not os.environ.get("C2C_TEST_INSTANCE_LOCK"),
    reason="Set C2C_TEST_INSTANCE_LOCK=1 to run instance-lock integration tests",
)

C2C_BIN = shutil.which("c2c") or "c2c"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_LOCK_HOLDER_SCRIPT = """\
import fcntl, os, sys, time

pid_path = sys.argv[1]

# Write our PID so OCaml can read it for diagnostics.
with open(pid_path, "w") as f:
    f.write(str(os.getpid()) + "\\n")

# Acquire POSIX advisory exclusive lock (same mechanism as OCaml Unix.lockf F_TLOCK).
fd = open(pid_path, "r+")
fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

# Signal parent that the lock is held.
sys.stdout.write("locked\\n")
sys.stdout.flush()

# Hold the lock until killed.
time.sleep(120)
"""


def _start_lock_holder(pid_path: Path) -> subprocess.Popen:
    """Spawn a subprocess that holds a POSIX exclusive lock on pid_path."""
    proc = subprocess.Popen(
        [sys.executable, "-c", _LOCK_HOLDER_SCRIPT, str(pid_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 5.0
    line = b""
    while time.monotonic() < deadline:
        proc.stdout.fileno()  # keep alive
        import select
        ready, _, _ = select.select([proc.stdout], [], [], 0.1)
        if ready:
            line = proc.stdout.readline()
            break
    assert line.strip() == b"locked", f"lock holder failed to acquire: {line!r}"
    return proc


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_second_start_exits_fatal_when_instance_locked(tmp_path: Path) -> None:
    """Second `c2c start` for the same name fails with FATAL when lock is held."""
    inst_name = "lock-test-inst"
    inst_dir = tmp_path / inst_name
    inst_dir.mkdir()
    pid_path = inst_dir / "outer.pid"

    lock_proc = _start_lock_holder(pid_path)
    try:
        env = {
            **os.environ,
            "C2C_INSTANCES_DIR": str(tmp_path),
        }
        result = subprocess.run(
            [C2C_BIN, "start", "opencode", "-n", inst_name, "--auto"],
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
    finally:
        lock_proc.kill()
        lock_proc.wait()

    assert result.returncode == 1, (
        f"Expected exit 1, got {result.returncode}.\nstderr: {result.stderr}"
    )
    # Old pid-file check says "ERROR"; new lockf check says "FATAL". Both are valid.
    assert ("FATAL" in result.stderr or "ERROR" in result.stderr), (
        f"Expected FATAL or ERROR in stderr:\n{result.stderr}"
    )
    assert inst_name in result.stderr, f"Expected instance name in stderr:\n{result.stderr}"


def test_second_start_includes_pid_in_error(tmp_path: Path) -> None:
    """FATAL message includes the PID of the conflicting process."""
    inst_name = "lock-test-pid"
    inst_dir = tmp_path / inst_name
    inst_dir.mkdir()
    pid_path = inst_dir / "outer.pid"

    lock_proc = _start_lock_holder(pid_path)
    try:
        env = {**os.environ, "C2C_INSTANCES_DIR": str(tmp_path)}
        result = subprocess.run(
            [C2C_BIN, "start", "opencode", "-n", inst_name, "--auto"],
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
    finally:
        lock_proc.kill()
        lock_proc.wait()

    assert result.returncode == 1
    # The PID written by the lock holder should appear in the FATAL message.
    holder_pid = str(lock_proc.pid)
    assert holder_pid in result.stderr or "unknown" in result.stderr, (
        f"Expected pid {holder_pid} or 'unknown' in stderr:\n{result.stderr}"
    )


def test_stop_message_in_fatal_error(tmp_path: Path) -> None:
    """FATAL message includes `c2c stop <name>` hint."""
    inst_name = "lock-test-stop"
    inst_dir = tmp_path / inst_name
    inst_dir.mkdir()
    pid_path = inst_dir / "outer.pid"

    lock_proc = _start_lock_holder(pid_path)
    try:
        env = {**os.environ, "C2C_INSTANCES_DIR": str(tmp_path)}
        result = subprocess.run(
            [C2C_BIN, "start", "opencode", "-n", inst_name, "--auto"],
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
    finally:
        lock_proc.kill()
        lock_proc.wait()

    assert result.returncode == 1
    assert f"c2c stop {inst_name}" in result.stderr, (
        f"Expected 'c2c stop {inst_name}' in stderr:\n{result.stderr}"
    )
