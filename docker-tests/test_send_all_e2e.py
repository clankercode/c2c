"""
End-to-end tests for the `c2c send-all` broadcast command.

Covers:
  - `send-all` delivers a DM to every registered peer except the sender
  - each recipient sees the broadcast in their inbox
  - the sender does not receive their own broadcast

Runs in the sealed Docker test environment.
"""
import json
import os
import subprocess

import pytest

C2C_CLI = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


pytestmark = pytest.mark.skipif(
    not os.path.exists(C2C_CLI),
    reason=f"c2c binary not found at {C2C_CLI}",
)


def _run(argv, session_id=None, alias=None, timeout=10):
    """Run the c2c CLI in the test environment."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen(
        [C2C_CLI] + argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    stdout, stderr = proc.communicate(timeout=timeout)
    return subprocess.CompletedProcess(
        args=[C2C_CLI] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )


def _register(alias, session_id):
    r = _run(["register", "--alias", alias], session_id=session_id, alias=alias)
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _poll_inbox(session_id):
    r = _run(["poll-inbox", "--json"], session_id=session_id)
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def test_send_all_delivers_to_all_other_peers():
    """send-all reaches every registered peer except the sender."""
    uid = "sa-001"
    sender_alias = f"sa-sender-{uid}"
    sender_session = f"sa-sender-sess-{uid}"
    recipients = [
        (f"sa-rcpt-1-{uid}", f"sa-rcpt-1-sess-{uid}"),
        (f"sa-rcpt-2-{uid}", f"sa-rcpt-2-sess-{uid}"),
        (f"sa-rcpt-3-{uid}", f"sa-rcpt-3-sess-{uid}"),
    ]
    msg = f"broadcast {uid}"

    _register(sender_alias, sender_session)
    for alias, sess in recipients:
        _register(alias, sess)

    r = _run(["send-all", msg], session_id=sender_session, alias=sender_alias)
    assert r.returncode == 0, f"send-all failed: {r.stderr}"

    # Every recipient should see the broadcast.
    for alias, sess in recipients:
        inbox = _poll_inbox(sess)
        assert any(m.get("content", "") == msg and m.get("from_alias") == sender_alias
                   for m in inbox), f"{alias} did not receive broadcast: {inbox}"

    # The sender should not receive their own message.
    sender_inbox = _poll_inbox(sender_session)
    assert not any(m.get("content", "") == msg for m in sender_inbox), \
        f"sender received own broadcast: {sender_inbox}"


def test_send_all_with_no_other_peers_is_noop():
    """send-all with only the sender registered is a successful no-op."""
    uid = "sa-002"
    alias = f"sa-lone-{uid}"
    session_id = f"sa-lone-sess-{uid}"

    _register(alias, session_id)

    r = _run(["send-all", "hello anyone"], session_id=session_id, alias=alias)
    assert r.returncode == 0, f"send-all failed: {r.stderr}"

    inbox = _poll_inbox(session_id)
    assert inbox == [], f"sender should have empty inbox: {inbox}"
