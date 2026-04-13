#!/usr/bin/env python3
"""Phase 6 hardening tests — deduplication, GC, retry semantics.

Tests:
  - Duplicate message_id → exactly-once delivery (not delivered twice)
  - GC removes expired leases + prunes orphan inboxes
  - GC prunes room members whose leases have expired
  - Connector outbox retry: failed messages stay in outbox for next tick
  - Connector retry succeeds when target registers later
  - HTTP /gc endpoint
"""
from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import InMemoryRelay  # noqa: E402
from c2c_relay_server import start_server_thread  # noqa: E402
from c2c_relay_connector import RelayClient, RelayConnector  # noqa: E402
from tests.test_relay_connector import (  # noqa: E402
    queue_outbound,
    read_inbox,
    write_registry,
)


# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

class DeduplicationTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("n", "s-alice", alias="alice")
        self.relay.register("n", "s-bob", alias="bob")

    def test_duplicate_send_not_delivered_twice(self):
        """Sending with the same message_id twice delivers exactly once."""
        msg_id = "dedup-test-001"
        self.relay.send("alice", "bob", "hello", message_id=msg_id)
        # Second send with same ID — should be a no-op
        result = self.relay.send("alice", "bob", "hello again", message_id=msg_id)
        self.assertTrue(result.get("duplicate"))

        msgs = self.relay.poll_inbox("n", "s-bob")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "hello")

    def test_different_message_ids_both_delivered(self):
        self.relay.send("alice", "bob", "msg-1", message_id="id-a")
        self.relay.send("alice", "bob", "msg-2", message_id="id-b")
        msgs = self.relay.poll_inbox("n", "s-bob")
        self.assertEqual(len(msgs), 2)

    def test_dedup_window_evicts_oldest(self):
        """When window fills, oldest IDs are evicted and can be re-seen."""
        relay = InMemoryRelay(dedup_window=3)
        relay.register("n", "s-a", alias="a")
        relay.register("n", "s-b", alias="b")
        # Fill window with ids 0,1,2
        for i in range(3):
            relay.send("a", "b", f"m{i}", message_id=f"id-{i}")
        relay.poll_inbox("n", "s-b")  # drain

        # Now add id-3 → evicts id-0
        relay.send("a", "b", "m3", message_id="id-3")
        relay.poll_inbox("n", "s-b")  # drain

        # id-0 was evicted → it's new again
        result = relay.send("a", "b", "re-m0", message_id="id-0")
        self.assertFalse(result.get("duplicate"))
        msgs = relay.poll_inbox("n", "s-b")
        self.assertEqual(len(msgs), 1)

    def test_dedup_http_endpoint(self):
        """POST /send with same message_id twice delivers once via HTTP."""
        server, _ = start_server_thread("127.0.0.1", 0, token="ded")
        port = server.server_address[1]
        client = RelayClient(f"http://127.0.0.1:{port}", token="ded")
        try:
            sfx = str(int(time.time() * 1000))
            client.register("n-d", f"s-d-a-{sfx}", f"ded-alice-{sfx}")
            client.register("n-d", f"s-d-b-{sfx}", f"ded-bob-{sfx}")
            msg_id = f"dedup-http-{sfx}"
            r1 = client.send(f"ded-alice-{sfx}", f"ded-bob-{sfx}", "first",
                             message_id=msg_id)
            self.assertTrue(r1.get("ok"))
            r2 = client.send(f"ded-alice-{sfx}", f"ded-bob-{sfx}", "second",
                             message_id=msg_id)
            self.assertTrue(r2.get("ok"))  # duplicate returns ok=True
            msgs = client.poll_inbox(f"n-d", f"s-d-b-{sfx}")
            self.assertEqual(len(msgs), 1)
            self.assertEqual(msgs[0]["content"], "first")
        finally:
            server.shutdown()


# ---------------------------------------------------------------------------
# GC
# ---------------------------------------------------------------------------

class RelayGCTests(unittest.TestCase):
    def test_gc_removes_expired_leases(self):
        relay = InMemoryRelay()
        relay.register("n", "s1", alias="short-lived", ttl=0.01)
        relay.register("n", "s2", alias="long-lived", ttl=300.0)
        time.sleep(0.05)
        result = relay.gc()
        self.assertIn("short-lived", result["expired_leases"])
        self.assertNotIn("long-lived", result["expired_leases"])

        peers = relay.list_peers(include_dead=False)
        aliases = [p["alias"] for p in peers]
        self.assertNotIn("short-lived", aliases)
        self.assertIn("long-lived", aliases)

    def test_gc_prunes_orphan_inboxes(self):
        relay = InMemoryRelay()
        relay.register("n", "s1", alias="gone", ttl=0.01)
        relay.register("n", "s2", alias="alive", ttl=300.0)
        # Deliver a message to "gone" before it expires
        relay._inboxes[("n", "s1")] = [{"content": "lost message"}]
        time.sleep(0.05)
        result = relay.gc()
        self.assertGreater(result["pruned_inboxes"], 0)
        # Inbox for dead session is gone
        self.assertEqual(relay.peek_inbox("n", "s1"), [])

    def test_gc_removes_expired_room_members(self):
        relay = InMemoryRelay()
        relay.register("n", "s1", alias="short", ttl=0.01)
        relay.register("n", "s2", alias="long", ttl=300.0)
        relay.join_room("short", "lounge")
        relay.join_room("long", "lounge")
        time.sleep(0.05)
        relay.gc()
        rooms = relay.list_rooms()
        r = next((x for x in rooms if x["room_id"] == "lounge"), None)
        self.assertIsNotNone(r)
        self.assertNotIn("short", r["members"])
        self.assertIn("long", r["members"])

    def test_gc_http_endpoint(self):
        server, _ = start_server_thread("127.0.0.1", 0, token="gc")
        port = server.server_address[1]
        client = RelayClient(f"http://127.0.0.1:{port}", token="gc")
        try:
            sfx = str(int(time.time() * 1000))
            client.register("n-gc", f"s-gc-{sfx}", f"gc-peer-{sfx}", ttl=0.01)
            time.sleep(0.05)
            r = client._request("GET", "/gc")
            self.assertTrue(r["ok"])
            self.assertIn("expired_leases", r)
            self.assertIn(f"gc-peer-{sfx}", r["expired_leases"])
        finally:
            server.shutdown()


# ---------------------------------------------------------------------------
# Connector retry semantics
# ---------------------------------------------------------------------------

class ConnectorRetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, _ = start_server_thread("127.0.0.1", 0, token="retry")
        port = cls.server.server_address[1]
        cls.relay_url = f"http://127.0.0.1:{port}"
        cls.token = "retry"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self._dirs = []

    def tearDown(self):
        for d in self._dirs:
            d.cleanup()

    def _broker_root(self) -> Path:
        d = tempfile.TemporaryDirectory()
        self._dirs.append(d)
        return Path(d.name)

    def _connector(self, root: Path, node_id: str) -> RelayConnector:
        client = RelayClient(self.relay_url, token=self.token)
        return RelayConnector(client, root, node_id)

    def test_retry_delivers_on_second_tick(self):
        """Connector retries failed outbox entries on the next tick."""
        root_sender = self._broker_root()
        root_receiver = self._broker_root()

        sfx = str(int(time.time() * 1000))
        write_registry(root_sender, [{"session_id": f"ss-{sfx}", "alias": f"sa-{sfx}"}])
        conn_s = self._connector(root_sender, f"machine-s-{sfx}")
        conn_s.sync()  # register sender

        # Queue message to alias that isn't registered yet → fails
        queue_outbound(root_sender, f"sa-{sfx}", f"ta-{sfx}", "retry-msg")
        result1 = conn_s.sync()
        self.assertEqual(result1["outbox_failed"], 1)

        # Now register receiver
        write_registry(root_receiver, [{"session_id": f"sr-{sfx}", "alias": f"ta-{sfx}"}])
        conn_r = self._connector(root_receiver, f"machine-r-{sfx}")
        conn_r.sync()

        # Retry tick — should succeed now
        result2 = conn_s.sync()
        self.assertEqual(result2["outbox_forwarded"], 1)
        self.assertEqual(result2["outbox_failed"], 0)

        # Receiver picks it up
        conn_r.sync()
        msgs = read_inbox(root_receiver, f"sr-{sfx}")
        self.assertTrue(any(m["content"] == "retry-msg" for m in msgs))

    def test_duplicate_retry_delivers_once(self):
        """Retrying a message with the same message_id delivers exactly once."""
        root_a = self._broker_root()
        root_b = self._broker_root()
        sfx = "dup-" + str(int(time.time() * 1000))

        write_registry(root_a, [{"session_id": f"sa-{sfx}", "alias": f"aa-{sfx}"}])
        write_registry(root_b, [{"session_id": f"sb-{sfx}", "alias": f"ab-{sfx}"}])
        conn_a = self._connector(root_a, f"node-a-{sfx}")
        conn_b = self._connector(root_b, f"node-b-{sfx}")
        conn_a.sync()
        conn_b.sync()

        # Manually queue the same message_id twice (simulating retry after
        # network timeout where first send succeeded but ack was lost)
        import uuid
        msg_id = str(uuid.uuid4())
        outbox = root_a / "remote-outbox.jsonl"
        entry = {"from_alias": f"aa-{sfx}", "to_alias": f"ab-{sfx}",
                 "content": "exactly-once", "message_id": msg_id}
        with outbox.open("a") as f:
            f.write(json.dumps(entry) + "\n")
            f.write(json.dumps(entry) + "\n")  # duplicate

        conn_a.sync()
        conn_b.sync()

        msgs = read_inbox(root_b, f"sb-{sfx}")
        delivered = [m for m in msgs if m.get("content") == "exactly-once"]
        self.assertEqual(len(delivered), 1)


if __name__ == "__main__":
    unittest.main()
