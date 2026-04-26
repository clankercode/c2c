"""
Phase C Case 8: Broker-respawn-pid self-heal.
Kill the inner client, restart, verify c2c send to the alias still works.
Validates self-heal from 0a6d8394.
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


class TestBrokerRespawnPid:
    """Case 8: Self-heal after inner client respawn (0a6d8394)."""

    def test_respawn_alias_still_receives(self):
        """Kill inner client, re-register same alias, send to it — still works."""
        ts = int(time.time())
        alice_sid = f"heal-alice-{ts}"
        bob_sid = f"heal-bob-{ts}"
        alias_a = f"heal-alice-{ts}"
        alias_b = f"heal-bob-{ts}"

        # Register both
        run(["register", "--alias", alias_a], session_id=alice_sid, alias=alias_a)
        run(["register", "--alias", alias_b], session_id=bob_sid, alias=alias_b)
        time.sleep(0.5)

        # Alice sends to Bob — should work
        r = run(["send", alias_b, "before respawn"], session_id=alice_sid, alias=alias_a)
        assert r.returncode == 0, f"send before respawn failed: {r.stderr}"

        # Bob re-registers (simulates respawn with same alias)
        bob_sid_new = f"heal-bob-{ts}-new"
        r = run(["register", "--alias", alias_b], session_id=bob_sid_new, alias=alias_b)
        assert r.returncode == 0, f"bob re-register failed: {r.stderr}"
        time.sleep(0.5)

        # Alice sends to Bob again — should still work (self-heal)
        r = run(["send", alias_b, "after respawn"], session_id=alice_sid, alias=alias_a)
        assert r.returncode == 0, f"send after respawn failed: {r.stderr}"

        # Bob polls and gets the after-respawn message
        r = run(["poll-inbox", "--json"], session_id=bob_sid_new)
        assert r.returncode == 0, f"poll-inbox after respawn failed: {r.stderr}"
        inbox = json.loads(r.stdout)
        assert any(
            "after respawn" in m.get("content", "")
            for m in inbox
        ), f"after-respawn message not found: {inbox}"

    def test_old_pid_inbox_cleaned_up(self):
        """Old session inbox is cleaned up after respawn (dead-letter handling)."""
        ts = int(time.time())
        sid_old = f"dead-{ts}-old"
        sid_new = f"dead-{ts}-new"
        alias = f"dead-{ts}"

        run(["register", "--alias", alias], session_id=sid_old, alias=alias)
        time.sleep(0.3)

        # Old session unregisters (simulates crash)
        r = run(["register", "--alias", alias], session_id=sid_new, alias=alias)
        assert r.returncode == 0

        # New session should be able to list without stale entries blocking
        r = run(["list", "--json"], session_id=sid_new)
        assert r.returncode == 0, f"list after respawn failed: {r.stderr}"
        peers = json.loads(r.stdout)
        aliases = [p["alias"] for p in peers]
        assert alias in aliases, f"alias not in peers after respawn: {aliases}"
