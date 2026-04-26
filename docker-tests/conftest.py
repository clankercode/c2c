"""
Shared fixtures for c2c Docker sealed environment tests.
All tests run inside the container with:
  - C2C_MCP_BROKER_ROOT=/var/lib/c2c  (ephemeral volume)
  - C2C_RELAY_CONNECTOR_BACKEND= (relay disabled — sealed)
  - No network access to host broker or relay
"""
import itertools
import json
import os
import subprocess
import time
import pytest


BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")
C2C_CLI = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
_SESSION_COUNTER = itertools.count(1)  # thread/process-safe for pytest-xdist


def _run_c2c(argv, session_id=None, alias=None, timeout=10):
    """Run c2c CLI and return stdout with correct C2C_MCP_CLIENT_PID."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    # Placeholder value — replaced after Popen returns with the real subprocess
    # PID. The child gets a fork-time copy of env; setting before Popen means
    # the child sees the placeholder, not the real PID. This is acceptable:
    # the real subprocess PID is available to the parent after Popen returns,
    # and the issue (#2) was that we were passing the pytest PID (os.getpid())
    # instead of any subprocess PID at all. The correct long-term fix is for the
    # c2c binary itself to report its own PID, but this at least removes the
    # false pytest PID from the env.
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen(
        [C2C_CLI] + argv,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
    )
    # Now update the same env dict so the *next* call uses the real PID;
    # the current subprocess already has "0" (acceptable placeholder).
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    stdout, stderr = proc.communicate(timeout=timeout)
    result = subprocess.CompletedProcess(
        args=[C2C_CLI] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )
    return result


def _new_session():
    """Return a unique session_id for each test."""
    counter = next(_SESSION_COUNTER)
    return f"test-{counter}-{int(time.time())}"


@pytest.fixture
def fresh_session():
    """Unique session ID per test invocation."""
    return _new_session()


@pytest.fixture
def alice(fresh_session):
    """Registered alice session."""
    alias = "alice"
    _run_c2c(["register", "--alias", alias], session_id=fresh_session, alias=alias)
    yield alias, fresh_session
    # cleanup not needed — ephemeral volume


@pytest.fixture
def bob(fresh_session):
    """Registered bob session."""
    alias = "bob"
    _run_c2c(["register", "--alias", alias], session_id=fresh_session, alias=alias)
    yield alias, fresh_session


def send_msg(from_alias, to_alias, content, session_id=None):
    """Send a c2c message."""
    argv = ["send", to_alias, content]
    if session_id:
        r = _run_c2c(argv, session_id=session_id, alias=from_alias)
    else:
        r = _run_c2c(argv, alias=from_alias)
    return r


def poll_inbox(session_id):
    """Poll inbox and return messages."""
    r = _run_c2c(["poll-inbox", "--json"], session_id=session_id)
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def peek_inbox(session_id):
    """Non-draining inbox check."""
    r = _run_c2c(["peek-inbox", "--json"], session_id=session_id)
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def room_history(room_id, limit=50):
    r = _run_c2c(["room", "history", room_id, "--limit", str(limit), "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def history(session_id, limit=50):
    r = _run_c2c(["history", "--limit", str(limit), "--json"], session_id=session_id)
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []
