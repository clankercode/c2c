"""Tests for c2c_relay_rooms — relay room CLI wrapper.

Uses a live relay server started on an ephemeral port (same pattern as
test_c2c_relay_server.py) so no mocking of HTTP is needed.
"""
from __future__ import annotations

import json
import sys
import threading
import unittest
from io import StringIO

sys.path.insert(0, ".")

from c2c_relay_contract import InMemoryRelay
from c2c_relay_server import start_server_thread
import c2c_relay_rooms as rooms_cli


def _make_server() -> tuple:
    """Start a relay server on an ephemeral port. Returns (server, url, token)."""
    token = "test-relay-rooms-token"
    server, _thread = start_server_thread(port=0, token=token)
    _, port = server.server_address
    url = f"http://127.0.0.1:{port}"
    return server, url, token


class _CliRunner:
    """Helper to call main() with captured stdout and a fixed relay URL."""

    def __init__(self, url: str, token: str):
        self.url = url
        self.token = token

    def run(self, argv: list[str], *, capture_stdout: bool = True) -> tuple[int, str]:
        """Run c2c relay rooms with given argv. Returns (exit_code, stdout)."""
        full_argv = ["--relay-url", self.url, "--token", self.token] + argv
        if capture_stdout:
            buf = StringIO()
            old_stdout = sys.stdout
            sys.stdout = buf
            try:
                rc = rooms_cli.main(full_argv)
            finally:
                sys.stdout = old_stdout
            return rc, buf.getvalue()
        return rooms_cli.main(full_argv), ""


class TestRelayRoomsHelp(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_no_args_returns_2(self):
        rc = rooms_cli.main([])
        self.assertEqual(rc, 2)

    def test_unknown_subcommand_returns_2(self):
        rc = rooms_cli.main(["--relay-url", self.url, "--token", self.token, "bogus"])
        self.assertEqual(rc, 2)


class TestRelayRoomsList(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_list_empty(self):
        rc, out = self.runner.run(["list"])
        self.assertEqual(rc, 0)
        self.assertIn("no rooms", out)

    def test_list_after_join(self):
        # Register a session then join a room
        relay = self.server.relay
        relay.register("n1", "s1", "alice")
        relay.join_room("alice", "lobby")

        rc, out = self.runner.run(["list"])
        self.assertEqual(rc, 0)
        self.assertIn("lobby", out)
        self.assertIn("alice", out)

    def test_list_json(self):
        relay = self.server.relay
        relay.register("n1", "s1", "bob")
        relay.join_room("bob", "chat")

        rc, out = self.runner.run(["list", "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])
        rooms = data["rooms"]
        rids = [r["room_id"] for r in rooms]
        self.assertIn("chat", rids)


class TestRelayRoomsJoin(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_join_room(self):
        relay = self.server.relay
        relay.register("n1", "s1", "carol")
        rc, out = self.runner.run(["join", "myroom", "--alias", "carol"])
        self.assertEqual(rc, 0)
        self.assertIn("myroom", out)

    def test_join_room_json(self):
        relay = self.server.relay
        relay.register("n1", "s1", "dave")
        rc, out = self.runner.run(["join", "room2", "--alias", "dave", "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])

    def test_join_idempotent(self):
        relay = self.server.relay
        relay.register("n1", "s1", "eve")
        relay.join_room("eve", "room3")
        rc, out = self.runner.run(["join", "room3", "--alias", "eve"])
        self.assertEqual(rc, 0)  # idempotent: always succeeds
        self.assertIn("room3", out)


class TestRelayRoomsLeave(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_leave_after_join(self):
        relay = self.server.relay
        relay.register("n1", "s1", "frank")
        relay.join_room("frank", "exitroom")

        rc, out = self.runner.run(["leave", "exitroom", "--alias", "frank"])
        self.assertEqual(rc, 0)
        self.assertIn("left room", out.lower())
        self.assertIn("exitroom", out)

        # Verify membership cleared
        rooms = relay.list_rooms()
        exitroom = next((r for r in rooms if r["room_id"] == "exitroom"), None)
        if exitroom:
            self.assertNotIn("frank", exitroom.get("members", []))

    def test_leave_not_member_says_so(self):
        # leave when not a member: rc=0, but output says "not a member"
        relay = self.server.relay
        relay.register("n1", "s1", "grace")
        rc, out = self.runner.run(["leave", "emptyroom", "--alias", "grace"])
        self.assertEqual(rc, 0)
        self.assertIn("not a member", out.lower())


class TestRelayRoomsSend(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_send_to_room(self):
        relay = self.server.relay
        relay.register("n1", "s1", "henry")
        relay.register("n2", "s2", "iris")
        relay.join_room("henry", "chan1")
        relay.join_room("iris", "chan1")

        rc, out = self.runner.run(["send", "chan1", "hello", "world", "--alias", "henry"])
        self.assertEqual(rc, 0)
        self.assertIn("1 delivered", out)

        # iris should have a message
        msgs = relay.poll_inbox("n2", "s2")
        user_msgs = [m for m in msgs if m["content"] == "hello world"]
        self.assertEqual(len(user_msgs), 1)

    def test_send_json(self):
        relay = self.server.relay
        relay.register("n1", "s1", "jake")
        relay.register("n2", "s2", "kim")
        relay.join_room("jake", "chan2")
        relay.join_room("kim", "chan2")

        rc, out = self.runner.run(["send", "chan2", "test msg", "--alias", "jake", "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])
        self.assertEqual(len(data.get("delivered_to", [])), 1)


class TestRelayRoomsHistory(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()
        self.runner = _CliRunner(self.url, self.token)

    def tearDown(self):
        self.server.shutdown()

    def test_history_empty(self):
        relay = self.server.relay
        relay.register("n1", "s1", "leo")
        relay.join_room("leo", "hist-room")

        rc, out = self.runner.run(["history", "hist-room"])
        self.assertEqual(rc, 0)
        self.assertIn("leo joined room hist-room", out)
        self.assertIn("c2c-system", out)

    def test_history_after_send(self):
        relay = self.server.relay
        relay.register("n1", "s1", "mia")
        relay.register("n2", "s2", "ned")
        relay.join_room("mia", "hist2")
        relay.join_room("ned", "hist2")
        relay.send_room("mia", "hist2", "first message")

        rc, out = self.runner.run(["history", "hist2"])
        self.assertEqual(rc, 0)
        self.assertIn("first message", out)
        self.assertIn("mia", out)

    def test_history_json(self):
        relay = self.server.relay
        relay.register("n1", "s1", "otto")
        relay.join_room("otto", "hist3")
        relay.send_room("otto", "hist3", "solo msg")

        rc, out = self.runner.run(["history", "hist3", "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])
        self.assertEqual(data["history"][-1]["content"], "solo msg")

    def test_history_limit(self):
        relay = self.server.relay
        relay.register("n1", "s1", "pat")
        relay.join_room("pat", "hist4")
        for i in range(5):
            relay.send_room("pat", "hist4", f"msg{i}")

        rc, out = self.runner.run(["history", "hist4", "--limit", "3", "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertEqual(len(data["history"]), 3)


if __name__ == "__main__":
    unittest.main()
