"""
Phase C Case 7: Ephemeral docs-up-to-date check (#284 contract).
After sending an ephemeral message, c2c history does NOT show it
but poll_inbox DID deliver it.
"""
import json
import os
import subprocess
import time
import pytest


C2C = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


def run(argv, session_id=None, alias=None):
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    # Pass session_id so resolve_alias can look up this session's registered alias.
    if session_id is not None:
        env["C2C_MCP_SESSION_ID"] = session_id
    # Also set AUTO_REGISTER_ALIAS so the subprocess has an alias identity even
    # before register has been called (e.g. for send before register in test flow).
    if alias is not None:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    # Use Popen to capture real subprocess PID instead of pytest PID.
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen(
        [C2C] + argv,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
    )
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    stdout, stderr = proc.communicate()
    return subprocess.CompletedProcess(
        args=[C2C] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )


class TestEphemeralContract:
    """Case 7: Ephemeral message contract — delivered by poll_inbox but absent from history."""

    def test_ephemeral_not_in_history(self):
        """Ephemeral message: poll_inbox returns it, but history excludes it."""
        alice_sid = f"eph-alice-{int(time.time())}"
        bob_sid = f"eph-bob-{int(time.time())}"
        alias_a = f"eph-alice-{int(time.time())}"
        alias_b = f"eph-bob-{int(time.time())}"

        # Register both
        run(["register", "--alias", alias_a], session_id=alice_sid, alias=alias_a)
        run(["register", "--alias", alias_b], session_id=bob_sid, alias=alias_b)
        time.sleep(0.5)

        # Alice sends ephemeral message to Bob
        ephemeral_msg = f"ephemeral secret {time.time()}"
        r = run(
            ["send", alias_b, ephemeral_msg, "--ephemeral"],
            session_id=alice_sid, alias=alias_a,
        )
        assert r.returncode == 0, f"ephemeral send failed: {r.stderr}"

        # Bob polls inbox — should receive it
        r = run(["poll-inbox", "--json"], session_id=bob_sid)
        assert r.returncode == 0, f"poll-inbox failed: {r.stderr}"
        inbox = json.loads(r.stdout)
        assert any(
            ephemeral_msg in m.get("content", "")
            for m in inbox
        ), f"ephemeral message not in poll_inbox: {inbox}"

        # Bob's history — ephemeral message must NOT appear
        r = run(["history", "--limit", "50", "--json"], session_id=bob_sid)
        assert r.returncode == 0, f"history failed: {r.stderr}"
        history = json.loads(r.stdout)
        assert not any(
            ephemeral_msg in m.get("content", "")
            for m in history
        ), f"ephemeral leaked into history: {history}"

    def test_non_ephemeral_still_in_history(self):
        """Non-ephemeral message appears in both poll_inbox and history."""
        alice_sid = f"ne-alice-{int(time.time())}"
        bob_sid = f"ne-bob-{int(time.time())}"
        alias_a = f"ne-alice-{int(time.time())}"
        alias_b = f"ne-bob-{int(time.time())}"

        run(["register", "--alias", alias_a], session_id=alice_sid, alias=alias_a)
        run(["register", "--alias", alias_b], session_id=bob_sid, alias=alias_b)
        time.sleep(0.5)

        # Alice sends regular (non-ephemeral) message
        regular_msg = f"regular message {time.time()}"
        r = run(["send", alias_b, regular_msg], session_id=alice_sid, alias=alias_a)
        assert r.returncode == 0, f"send failed: {r.stderr}"

        # Bob polls to drain
        r = run(["poll-inbox", "--json"], session_id=bob_sid)
        assert r.returncode == 0
        time.sleep(0.5)

        # Bob's history — regular message SHOULD appear
        r = run(["history", "--limit", "50", "--json"], session_id=bob_sid)
        assert r.returncode == 0
        history = json.loads(r.stdout)
        assert any(
            regular_msg in m.get("content", "")
            for m in history
        ), f"regular message not in history: {history}"
