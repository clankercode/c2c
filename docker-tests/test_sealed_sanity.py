"""
Phase C Cases 1-5: Baseline sanity tests in sealed Docker environment.
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
    env["C2C_MCP_CLIENT_PID"] = str(os.getpid())
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    r = subprocess.run([C2C] + argv, capture_output=True, text=True, env=env)
    return r


class TestSealedSanity:
    """Cases 1-5: baseline sealed-environment sanity checks."""

    def test_c2c_version(self):
        """Case 1: c2c --version in container."""
        r = run(["--version"])
        assert r.returncode == 0, f"version failed: {r.stderr}"
        assert r.stdout.startswith("0."), f"unexpected version: {r.stdout}"

    def test_c2c_help(self):
        """Case 1b: c2c --help works."""
        r = run(["--help"])
        assert r.returncode == 0, f"help failed: {r.stderr}"

    def test_register_and_list(self):
        """Case 2: register + list — local broker, no relay."""
        sid = "sanity-list-test"
        alias = "sanity-test"
        r = run(["register", "--alias", alias], session_id=sid, alias=alias)
        assert r.returncode == 0, f"register failed: {r.stderr}"

        r = run(["list", "--json"], session_id=sid, alias=alias)
        assert r.returncode == 0, f"list failed: {r.stderr}"
        peers = json.loads(r.stdout)
        aliases = [p["alias"] for p in peers]
        assert alias in aliases, f"alias {alias} not found in peers: {peers}"

    def test_send_and_poll_inbox(self):
        """Case 3: send + poll_inbox 1:1 messaging."""
        alice_sid = "sanity-alice"
        bob_sid = "sanity-bob"
        # Register both
        run(["register", "--alias", "sanity-alice"], session_id=alice_sid, alias="sanity-alice")
        run(["register", "--alias", "sanity-bob"], session_id=bob_sid, alias="sanity-bob")
        time.sleep(0.5)

        # Alice sends to Bob
        msg = f"hello bob at {__name__}"
        r = run(["send", "sanity-bob", msg], session_id=alice_sid, alias="sanity-alice")
        assert r.returncode == 0, f"send failed: {r.stderr}"

        # Bob polls inbox (with retry for async delivery)
        inbox = []
        for attempt in range(5):
            r = run(["poll-inbox", "--json"], session_id=bob_sid)
            if r.returncode == 0:
                try:
                    inbox = json.loads(r.stdout)
                    if any(msg in m.get("content", "") for m in inbox):
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.5 * (attempt + 1))
        assert any(msg in m.get("content", "") for m in inbox), \
            f"message '{msg}' not found in inbox after retries: {inbox}"

    def test_room_create_and_history(self):
        """Case 4: room creation + send_room + room_history."""
        sid = "sanity-room-test"
        alias = "sanity-room-host"
        run(["register", "--alias", alias], session_id=sid, alias=alias)
        time.sleep(0.5)

        room_id = "sanity-room-" + str(int(__import__("time").time()))
        r = run(["room", "join", room_id, "--json"], session_id=sid, alias=alias)
        assert r.returncode == 0, f"room join failed: {r.stderr}"
        result = json.loads(r.stdout)
        assert result.get("room_id") == room_id

        # Send a message to the room
        msg = f"room hello from {alias}"
        r = run(["rooms", "send", room_id, msg], session_id=sid, alias=alias)
        assert r.returncode == 0, f"room send failed: {r.stderr}"

        # Check history
        history_msgs = []
        for _ in range(5):
            r = run(["room", "history", room_id, "--limit", "10", "--json"], session_id=sid)
            if r.returncode == 0:
                try:
                    history_msgs = json.loads(r.stdout)
                    if any(msg in m.get("content", "") for m in history_msgs):
                        break
                except json.JSONDecodeError:
                    pass
            __import__("time").sleep(0.5 * (_ + 1))
        assert any(msg in m.get("content", "") for m in history_msgs), \
            f"message '{msg}' not found in room history: {history_msgs}"

    def test_room_leave(self):
        """Case 4b: leave room."""
        sid = "sanity-leave-test"
        alias = "sanity-leave-host"
        run(["register", "--alias", alias], session_id=sid, alias=alias)
        room_id = "sanity-leave-" + str(int(__import__("time").time()))
        run(["room", "join", room_id], session_id=sid, alias=alias)
        r = run(["room", "leave", room_id], session_id=sid, alias=alias)
        assert r.returncode == 0, f"room leave failed: {r.stderr}"

    def test_whoami(self):
        """Case 2b: whoami shows correct alias."""
        sid = "sanity-whoami"
        alias = "sanity-whoami-test"
        run(["register", "--alias", alias], session_id=sid, alias=alias)
        r = run(["whoami"], session_id=sid)
        assert r.returncode == 0, f"whoami failed: {r.stderr}"
        assert alias in r.stdout, f"whoami doesn't show alias: {r.stdout}"
