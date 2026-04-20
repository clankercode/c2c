#!/usr/bin/env python3
"""Room + broadcast tests for InMemoryRelay and HTTP relay server (Phase 4).

Tests join_room, leave_room, send_room, room_history, list_rooms, and send_all
at both the InMemoryRelay layer and the HTTP endpoint layer.
"""
from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import InMemoryRelay  # noqa: E402
from c2c_relay_server import start_server_thread  # noqa: E402

# Re-use the HTTP client from test_relay_server
from tests.test_relay_server import RelayClient as HTTPRelayClient  # noqa: E402

TOKEN = "room-test-token"


# ---------------------------------------------------------------------------
# InMemoryRelay room tests
# ---------------------------------------------------------------------------

class InMemoryRoomTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("n", "s-alice", alias="alice")
        self.relay.register("n", "s-bob", alias="bob")
        self.relay.register("n", "s-carol", alias="carol")

    def test_join_room_returns_ok(self):
        r = self.relay.join_room("alice", "general")
        self.assertTrue(r["ok"])
        self.assertEqual(r["room_id"], "general")

    def test_join_room_creates_room(self):
        self.relay.join_room("alice", "new-room")
        rooms = self.relay.list_rooms()
        ids = {r["room_id"] for r in rooms}
        self.assertIn("new-room", ids)

    def test_join_room_idempotent(self):
        self.relay.join_room("alice", "general")
        self.relay.join_room("alice", "general")
        rooms = self.relay.list_rooms()
        g = next(r for r in rooms if r["room_id"] == "general")
        self.assertEqual(g["members"].count("alice"), 1)

    def test_join_room_broadcasts_system_notice_to_all_members(self):
        self.relay.join_room("alice", "general")
        self.relay.poll_inbox("n", "s-alice")

        self.relay.join_room("bob", "general")

        alice_msgs = self.relay.poll_inbox("n", "s-alice")
        bob_msgs = self.relay.poll_inbox("n", "s-bob")
        for msgs in (alice_msgs, bob_msgs):
            notice = [m for m in msgs if m["content"] == "bob joined room general"]
            self.assertEqual(len(notice), 1)
            self.assertEqual(notice[0]["from_alias"], "c2c-system")
            self.assertEqual(notice[0]["to_alias"].split("#", 1)[1], "general")

    def test_join_room_records_system_notice_in_history(self):
        self.relay.join_room("alice", "lobby")

        history = self.relay.room_history("lobby")

        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["from_alias"], "c2c-system")
        self.assertEqual(history[0]["content"], "alice joined room lobby")

    def test_join_room_idempotent_does_not_repeat_system_notice(self):
        self.relay.join_room("alice", "quiet")
        self.relay.join_room("alice", "quiet")

        history = self.relay.room_history("quiet")

        self.assertEqual(
            [m["content"] for m in history],
            ["alice joined room quiet"],
        )

    def test_join_room_unknown_alias_raises(self):
        from c2c_relay_contract import RelayError, RELAY_ERR_UNKNOWN_ALIAS
        with self.assertRaises(RelayError) as ctx:
            self.relay.join_room("nobody", "general")
        self.assertEqual(ctx.exception.code, RELAY_ERR_UNKNOWN_ALIAS)

    def test_leave_room_removes_member(self):
        self.relay.join_room("alice", "general")
        self.relay.join_room("bob", "general")
        self.relay.leave_room("alice", "general")
        rooms = self.relay.list_rooms()
        g = next(r for r in rooms if r["room_id"] == "general")
        self.assertNotIn("alice", g["members"])
        self.assertIn("bob", g["members"])

    def test_leave_room_noop_if_not_member(self):
        r = self.relay.leave_room("alice", "nonexistent-room")
        self.assertTrue(r["ok"])

    def test_send_room_delivers_to_members_except_sender(self):
        self.relay.join_room("alice", "lounge")
        self.relay.join_room("bob", "lounge")
        self.relay.join_room("carol", "lounge")
        r = self.relay.send_room("alice", "lounge", "hello room")
        self.assertIn("bob", r["delivered_to"])
        self.assertIn("carol", r["delivered_to"])
        self.assertNotIn("alice", r["delivered_to"])

    def test_send_room_delivers_to_inbox(self):
        self.relay.join_room("alice", "lounge2")
        self.relay.join_room("bob", "lounge2")
        self.relay.send_room("alice", "lounge2", "msg for bob")
        msgs = self.relay.poll_inbox("n", "s-bob")
        self.assertTrue(any(m["content"] == "msg for bob" for m in msgs))

    def test_send_room_records_room_id_in_to_alias(self):
        self.relay.join_room("alice", "lounge3")
        self.relay.join_room("bob", "lounge3")
        self.relay.send_room("alice", "lounge3", "room tagged")
        msgs = self.relay.poll_inbox("n", "s-bob")
        tagged = [m for m in msgs if m["content"] == "room tagged"]
        self.assertTrue(tagged[0]["to_alias"].endswith("#lounge3"))

    def test_send_room_empty_room_returns_ok(self):
        r = self.relay.send_room("alice", "empty-room", "hello")
        self.assertTrue(r["ok"])
        self.assertEqual(r["delivered_to"], [])

    def test_room_history_records_sent_messages(self):
        self.relay.join_room("alice", "hist-room")
        self.relay.join_room("bob", "hist-room")
        self.relay.send_room("alice", "hist-room", "msg1")
        self.relay.send_room("bob", "hist-room", "msg2")
        history = self.relay.room_history("hist-room")
        contents = [h["content"] for h in history]
        self.assertIn("msg1", contents)
        self.assertIn("msg2", contents)

    def test_room_history_limit(self):
        self.relay.join_room("alice", "limit-room")
        self.relay.join_room("bob", "limit-room")
        self.relay.room_history("limit-room")
        for i in range(10):
            self.relay.send_room("alice", "limit-room", f"msg{i}")
        history = self.relay.room_history("limit-room", limit=3)
        self.assertEqual(len(history), 3)

    def test_room_history_empty_room(self):
        history = self.relay.room_history("no-such-room")
        self.assertEqual(history, [])

    def test_list_rooms_shows_all(self):
        self.relay.join_room("alice", "r1")
        self.relay.join_room("bob", "r2")
        rooms = self.relay.list_rooms()
        ids = {r["room_id"] for r in rooms}
        self.assertIn("r1", ids)
        self.assertIn("r2", ids)

    def test_list_rooms_row_shape(self):
        self.relay.join_room("alice", "shaped-room")
        rooms = self.relay.list_rooms()
        r = next(x for x in rooms if x["room_id"] == "shaped-room")
        for key in ("room_id", "member_count", "members"):
            self.assertIn(key, r)

    def test_send_room_dead_member_goes_to_dead_letter(self):
        self.relay.join_room("alice", "dead-room")
        self.relay.join_room("bob", "dead-room")
        self.relay._tick_lease("bob", 1000)  # expire bob's lease
        r = self.relay.send_room("alice", "dead-room", "for bob")
        self.assertIn("bob", r["skipped"])
        dl = self.relay.dead_letter()
        self.assertTrue(any(e["to_alias"].startswith("bob") for e in dl))


class InMemorySendAllTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("n", "s-a", alias="aa")
        self.relay.register("n", "s-b", alias="bb")
        self.relay.register("n", "s-c", alias="cc")

    def test_send_all_delivers_to_all_except_sender(self):
        r = self.relay.send_all("aa", "broadcast")
        self.assertIn("bb", r["delivered_to"])
        self.assertIn("cc", r["delivered_to"])
        self.assertNotIn("aa", r["delivered_to"])

    def test_send_all_delivers_to_inboxes(self):
        self.relay.send_all("aa", "hello all")
        bb_msgs = self.relay.poll_inbox("n", "s-b")
        cc_msgs = self.relay.poll_inbox("n", "s-c")
        self.assertTrue(any(m["content"] == "hello all" for m in bb_msgs))
        self.assertTrue(any(m["content"] == "hello all" for m in cc_msgs))

    def test_send_all_skips_dead_aliases(self):
        self.relay._tick_lease("bb", 1000)
        r = self.relay.send_all("aa", "skip dead")
        self.assertNotIn("bb", r["delivered_to"])
        self.assertIn("bb", r["skipped"])


# ---------------------------------------------------------------------------
# HTTP room tests
# ---------------------------------------------------------------------------

class HTTPRoomClient(HTTPRelayClient):
    """Extends RelayClient with room methods."""

    def join_room(self, alias: str, room_id: str) -> dict:
        return self.post("/join_room", {"alias": alias, "room_id": room_id})

    def leave_room(self, alias: str, room_id: str) -> dict:
        return self.post("/leave_room", {"alias": alias, "room_id": room_id})

    def send_room(self, from_alias: str, room_id: str, content: str) -> dict:
        return self.post("/send_room", {"from_alias": from_alias,
                                        "room_id": room_id, "content": content})

    def room_history(self, room_id: str, limit: int = 50) -> list[dict]:
        r = self.post("/room_history", {"room_id": room_id, "limit": limit})
        return r.get("history", [])

    def list_rooms(self) -> list[dict]:
        r = self.get("/list_rooms")
        return r.get("rooms", [])

    def send_all(self, from_alias: str, content: str) -> dict:
        return self.post("/send_all", {"from_alias": from_alias, "content": content})


class HTTPRoomTests(unittest.TestCase):
    server = None

    @classmethod
    def setUpClass(cls):
        cls.server, _ = start_server_thread("127.0.0.1", 0, token=TOKEN)
        port = cls.server.server_address[1]
        cls.client = HTTPRoomClient(f"http://127.0.0.1:{port}", token=TOKEN)
        sfx = "hr" + str(int(time.time() * 1000))
        cls.alice = f"alice-{sfx}"
        cls.bob = f"bob-{sfx}"
        cls.carol = f"carol-{sfx}"
        cls.client.register("n-hr", f"s-alice-{sfx}", cls.alice)
        cls.client.register("n-hr", f"s-bob-{sfx}", cls.bob)
        cls.client.register("n-hr", f"s-carol-{sfx}", cls.carol)
        cls._node = "n-hr"
        cls._sess_alice = f"s-alice-{sfx}"
        cls._sess_bob = f"s-bob-{sfx}"
        cls._sfx = sfx

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_join_room_returns_ok(self):
        r = self.client.join_room(self.alice, f"room-{self._sfx}-a")
        self.assertTrue(r["ok"])

    def test_join_room_unknown_alias_returns_409(self):
        r = self.client.post("/join_room", {"alias": "nobody-xyz", "room_id": "x"})
        self.assertFalse(r["ok"])

    def test_send_room_fanout(self):
        room = f"fanout-{self._sfx}"
        self.client.join_room(self.alice, room)
        self.client.join_room(self.bob, room)
        self.client.join_room(self.carol, room)
        r = self.client.send_room(self.alice, room, "hello room via http")
        self.assertIn(self.bob, r["delivered_to"])
        self.assertIn(self.carol, r["delivered_to"])
        self.assertNotIn(self.alice, r["delivered_to"])

    def test_room_history_via_http(self):
        room = f"hist-{self._sfx}"
        self.client.join_room(self.alice, room)
        self.client.join_room(self.bob, room)
        self.client.send_room(self.alice, room, "hist-msg-1")
        self.client.send_room(self.bob, room, "hist-msg-2")
        history = self.client.room_history(room)
        contents = [h["content"] for h in history]
        self.assertIn("hist-msg-1", contents)
        self.assertIn("hist-msg-2", contents)

    def test_list_rooms_via_http(self):
        room = f"list-{self._sfx}"
        self.client.join_room(self.alice, room)
        rooms = self.client.list_rooms()
        ids = {r["room_id"] for r in rooms}
        self.assertIn(room, ids)

    def test_leave_room_removes_member(self):
        room = f"leave-{self._sfx}"
        self.client.join_room(self.alice, room)
        self.client.join_room(self.bob, room)
        self.client.leave_room(self.alice, room)
        rooms = self.client.list_rooms()
        matching = [r for r in rooms if r["room_id"] == room]
        self.assertEqual(len(matching), 1)
        self.assertNotIn(self.alice, matching[0]["members"])

    def test_send_all_via_http(self):
        r = self.client.send_all(self.alice, "broadcast via http")
        self.assertTrue(r["ok"])
        self.assertIn(self.bob, r["delivered_to"])
        self.assertIn(self.carol, r["delivered_to"])
        self.assertNotIn(self.alice, r["delivered_to"])

    def test_send_room_missing_fields_returns_400(self):
        r = self.client.post("/send_room", {"from_alias": self.alice})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "bad_request")

    def test_room_history_empty_room(self):
        history = self.client.room_history("never-existed-room-xyz")
        self.assertEqual(history, [])


if __name__ == "__main__":
    unittest.main()
