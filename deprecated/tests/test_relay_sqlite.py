#!/usr/bin/env python3
"""Tests for SQLiteRelay — parity with InMemoryRelay contract."""
from __future__ import annotations

import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import (  # noqa: E402
    RELAY_ERR_ALIAS_CONFLICT,
    RELAY_ERR_RECIPIENT_DEAD,
    RELAY_ERR_UNKNOWN_ALIAS,
    RelayError,
)
from c2c_relay_sqlite import SQLiteRelay  # noqa: E402
import c2c_relay_server  # noqa: E402


class SQLiteRelayContractTests(unittest.TestCase):
    """Contract parity tests for SQLiteRelay."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = Path(self.tmpdir) / "relay.db"
        self.relay = SQLiteRelay(self.db_path)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # --- registration ---

    def test_register_returns_ok(self):
        result = self.relay.register("node-a", "sess-1", alias="codex")
        self.assertTrue(result["ok"])
        self.assertEqual(result["alias"], "codex")

    def test_register_creates_inbox(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.assertEqual(self.relay.poll_inbox("node-a", "sess-1"), [])

    def test_register_same_alias_same_session_refreshes_lease(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay._tick_lease("codex", 100)
        before = self.relay.list_peers()[0]["last_seen"]
        import time
        time.sleep(0.01)
        self.relay.register("node-a", "sess-1", alias="codex")
        after = self.relay.list_peers()[0]["last_seen"]
        self.assertGreater(after, before)

    def test_register_same_alias_different_session_replaces(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        result = self.relay.register("node-a", "sess-2", alias="codex")
        self.assertTrue(result["ok"])
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 1)
        self.assertEqual(peers[0]["session_id"], "sess-2")

    def test_register_conflict_different_node(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        with self.assertRaises(RelayError) as cm:
            self.relay.register("node-b", "sess-2", alias="codex")
        self.assertEqual(cm.exception.code, RELAY_ERR_ALIAS_CONFLICT)

    def test_heartbeat_refreshes_lease(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay._tick_lease("codex", 100)
        before = self.relay.list_peers()[0]["last_seen"]
        import time
        time.sleep(0.01)
        result = self.relay.heartbeat("node-a", "sess-1")
        self.assertTrue(result["ok"])
        after = self.relay.list_peers()[0]["last_seen"]
        self.assertGreater(after, before)

    def test_heartbeat_unknown_session(self):
        with self.assertRaises(RelayError) as cm:
            self.relay.heartbeat("node-a", "sess-1")
        self.assertEqual(cm.exception.code, RELAY_ERR_UNKNOWN_ALIAS)

    def test_list_peers_excludes_dead_by_default(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=1.0)
        self.relay.register("node-a", "sess-2", alias="kimi", ttl=300.0)
        self.relay._tick_lease("codex", 2.0)
        alive = self.relay.list_peers()
        self.assertEqual([p["alias"] for p in alive], ["kimi"])

    def test_list_peers_include_dead(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=1.0)
        self.relay._tick_lease("codex", 2.0)
        all_peers = self.relay.list_peers(include_dead=True)
        self.assertEqual([p["alias"] for p in all_peers], ["codex"])

    # --- messaging ---

    def test_send_delivers_to_inbox(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi")
        result = self.relay.send("codex", "kimi", "hello")
        self.assertTrue(result["ok"])
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "hello")
        self.assertEqual(msgs[0]["from_alias"], "codex")

    def test_poll_inbox_drains(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.send("codex", "codex", "self-msg")
        first = self.relay.poll_inbox("node-a", "sess-1")
        self.assertEqual(len(first), 1)
        second = self.relay.poll_inbox("node-a", "sess-1")
        self.assertEqual(second, [])

    def test_peek_inbox_does_not_drain(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.send("codex", "codex", "self-msg")
        first = self.relay.peek_inbox("node-a", "sess-1")
        self.assertEqual(len(first), 1)
        second = self.relay.peek_inbox("node-a", "sess-1")
        self.assertEqual(len(second), 1)

    def test_send_unknown_alias_goes_to_dead_letter(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        with self.assertRaises(RelayError) as cm:
            self.relay.send("codex", "nobody", "hello")
        self.assertEqual(cm.exception.code, RELAY_ERR_UNKNOWN_ALIAS)
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["reason"], "unknown_alias")

    def test_send_dead_recipient_goes_to_dead_letter(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi", ttl=1.0)
        self.relay._tick_lease("kimi", 2.0)
        with self.assertRaises(RelayError) as cm:
            self.relay.send("codex", "kimi", "hello")
        self.assertEqual(cm.exception.code, RELAY_ERR_RECIPIENT_DEAD)
        dl = self.relay.dead_letter()
        self.assertEqual(dl[0]["reason"], "recipient_dead")

    def test_send_exactly_once_dedup(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi")
        msg_id = "my-msg-id-123"
        r1 = self.relay.send("codex", "kimi", "hello", message_id=msg_id)
        self.assertNotIn("duplicate", r1)
        r2 = self.relay.send("codex", "kimi", "hello", message_id=msg_id)
        self.assertTrue(r2.get("duplicate"))
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs), 1)

    # --- rooms ---

    def test_join_room_creates_room(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        result = self.relay.join_room("codex", "swarm-lounge")
        self.assertTrue(result["ok"])
        self.assertEqual(result["member_count"], 1)
        self.assertFalse(result["already_member"])

    def test_join_room_already_member(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.join_room("codex", "swarm-lounge")
        result = self.relay.join_room("codex", "swarm-lounge")
        self.assertTrue(result["already_member"])
        self.assertEqual(result["member_count"], 1)

    def test_leave_room_removes_member(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.join_room("codex", "swarm-lounge")
        result = self.relay.leave_room("codex", "swarm-lounge")
        self.assertTrue(result["removed"])
        self.assertEqual(result["member_count"], 0)

    def test_send_room_delivers_to_members(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi")
        self.relay.join_room("codex", "swarm-lounge")
        self.relay.join_room("kimi", "swarm-lounge")
        result = self.relay.send_room("codex", "swarm-lounge", "hi all")
        self.assertIn("kimi", result["delivered_to"])
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(msgs[0]["to_alias"], "kimi#swarm-lounge")

    def test_join_room_broadcasts_system_notice_to_all_members(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi")
        self.relay.join_room("codex", "swarm-lounge")
        self.relay.poll_inbox("node-a", "sess-1")

        self.relay.join_room("kimi", "swarm-lounge")

        codex_msgs = self.relay.poll_inbox("node-a", "sess-1")
        kimi_msgs = self.relay.poll_inbox("node-b", "sess-2")
        for msgs in (codex_msgs, kimi_msgs):
            notice = [
                m for m in msgs
                if m["content"] == "kimi joined room swarm-lounge"
            ]
            self.assertEqual(len(notice), 1)
            self.assertEqual(notice[0]["from_alias"], "c2c-system")
            self.assertEqual(notice[0]["to_alias"].split("#", 1)[1], "swarm-lounge")

    def test_join_room_records_system_notice_in_history(self):
        self.relay.register("node-a", "sess-1", alias="codex")

        self.relay.join_room("codex", "swarm-lounge")

        hist = self.relay.room_history("swarm-lounge")
        self.assertEqual(len(hist), 1)
        self.assertEqual(hist[0]["from_alias"], "c2c-system")
        self.assertEqual(hist[0]["content"], "codex joined room swarm-lounge")

    def test_join_room_idempotent_does_not_repeat_system_notice(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.join_room("codex", "swarm-lounge")
        self.relay.join_room("codex", "swarm-lounge")

        hist = self.relay.room_history("swarm-lounge")

        self.assertEqual(
            [m["content"] for m in hist],
            ["codex joined room swarm-lounge"],
        )

    def test_room_history_preserved(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.join_room("codex", "swarm-lounge")
        self.relay.send_room("codex", "swarm-lounge", "msg1")
        self.relay.send_room("codex", "swarm-lounge", "msg2")
        hist = self.relay.room_history("swarm-lounge")
        self.assertEqual([m["content"] for m in hist[-2:]], ["msg1", "msg2"])

    def test_list_rooms(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.join_room("codex", "room-a")
        self.relay.join_room("codex", "room-b")
        rooms = self.relay.list_rooms()
        self.assertEqual(sorted(r["room_id"] for r in rooms), ["room-a", "room-b"])

    # --- broadcast ---

    def test_send_all_broadcasts(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.register("node-b", "sess-2", alias="kimi")
        result = self.relay.send_all("codex", "broadcast")
        self.assertIn("kimi", result["delivered_to"])
        self.assertNotIn("codex", result["delivered_to"])
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(msgs[0]["content"], "broadcast")

    # --- GC ---

    def test_gc_removes_expired_leases_and_inboxes(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=300.0)
        self.relay.register("node-b", "sess-2", alias="kimi", ttl=1.0)
        self.relay.send("codex", "kimi", "hello")
        self.relay._tick_lease("kimi", 2.0)
        result = self.relay.gc()
        self.assertIn("kimi", result["expired_leases"])
        self.assertGreaterEqual(result["pruned_inboxes"], 1)
        alive = self.relay.list_peers()
        self.assertEqual([p["alias"] for p in alive], ["codex"])

    def test_gc_removes_expired_from_rooms(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=1.0)
        self.relay.join_room("codex", "swarm-lounge")
        self.relay._tick_lease("codex", 2.0)
        self.relay.gc()
        rooms = self.relay.list_rooms()
        self.assertEqual(rooms[0]["member_count"], 0)

    # --- persistence ---

    def test_data_persists_across_relay_instances(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay.send("codex", "codex", "self-msg")
        # New instance, same DB
        relay2 = SQLiteRelay(self.db_path)
        peers = relay2.list_peers()
        self.assertEqual(len(peers), 1)
        msgs = relay2.poll_inbox("node-a", "sess-1")
        self.assertEqual(msgs[0]["content"], "self-msg")


class SQLiteRelayServerUnitTests(unittest.TestCase):
    def test_make_server_can_use_sqlite_relay(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "relay.db"
            relay = SQLiteRelay(db_path)
            server = c2c_relay_server.make_server("127.0.0.1", 0, relay=relay)
            try:
                self.assertIs(server.relay, relay)
                server.relay.register("node-a", "sess-1", alias="codex")
                server.relay.send("codex", "codex", "persisted")
            finally:
                server.server_close()

            relay2 = SQLiteRelay(db_path)
            self.assertEqual(
                relay2.poll_inbox("node-a", "sess-1")[0]["content"],
                "persisted",
            )

    def test_sqlite_storage_requires_db_path(self):
        rc = c2c_relay_server.main(["--storage", "sqlite", "--listen", "127.0.0.1:0"])
        self.assertEqual(rc, 1)

class SQLiteRelayServerHTTPTests(unittest.TestCase):
    """Verify SQLiteRelay works inside c2c_relay_server.make_server."""

    def test_server_with_sqlite_relay_serves_http(self):
        import urllib.request
        import json
        from c2c_relay_server import make_server

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "relay.db"
            relay = SQLiteRelay(db_path)
            server = make_server("127.0.0.1", 0, token="test", relay=relay)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                url = f"http://{host}:{port}/health"
                with urllib.request.urlopen(url, timeout=5) as resp:
                    self.assertEqual(resp.status, 200)
                    data = json.loads(resp.read())
                    self.assertTrue(data["ok"])

                # Register via HTTP
                req = urllib.request.Request(
                    f"http://{host}:{port}/register",
                    data=json.dumps({
                        "node_id": "n1",
                        "session_id": "s1",
                        "alias": "codex",
                    }).encode(),
                    headers={
                        "Authorization": "Bearer test",
                        "Content-Type": "application/json",
                    },
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    self.assertEqual(resp.status, 200)

                # Verify persistence across a new relay instance using same DB
                relay2 = SQLiteRelay(db_path)
                peers = relay2.list_peers()
                self.assertEqual(len(peers), 1)
                self.assertEqual(peers[0]["alias"], "codex")
            finally:
                server.shutdown()


if __name__ == "__main__":
    unittest.main()
