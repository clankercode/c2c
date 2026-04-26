"""
Shared fixtures for c2c Docker sealed environment tests.
All tests run inside the container with:
  - C2C_MCP_BROKER_ROOT=/var/lib/c2c  (ephemeral volume)
  - C2C_RELAY_CONNECTOR_BACKEND= (relay disabled — sealed)
  - No network access to host broker or relay
"""
import json
import os
import subprocess
import time
import pytest


BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")
C2C_CLI = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
SESSION_COUNTER = 0


def _run_c2c(argv, session_id=None, alias=None, timeout=10):
    """Run c2c CLI and return stdout."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_MCP_CLIENT_PID"] = str(os.getpid())
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    result = subprocess.run(
        [C2C_CLI] + argv,
        capture_output=True, text=True, timeout=timeout, env=env,
    )
    return result


def _new_session():
    """Return a unique session_id for each test."""
    global SESSION_COUNTER
    SESSION_COUNTER += 1
    return f"test-{SESSION_COUNTER}-{int(time.time())}"


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
