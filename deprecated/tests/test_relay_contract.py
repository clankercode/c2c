#!/usr/bin/env python3
"""Tests for c2c_relay_contract — InMemoryRelay + derive_node_id.

Exercises the Phase-1 contract: register/heartbeat/list, 1:1 send/poll/peek,
dead-letter on unknown/dead recipients, and alias-conflict semantics.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import (  # noqa: E402
    RELAY_ERR_ALIAS_CONFLICT,
    RELAY_ERR_RECIPIENT_DEAD,
    RELAY_ERR_UNKNOWN_ALIAS,
    InMemoryRelay,
    RelayError,
    derive_node_id,
)


# ---------------------------------------------------------------------------
# derive_node_id
# ---------------------------------------------------------------------------

class DeriveNodeIdTests(unittest.TestCase):
    def test_returns_string(self):
        node_id = derive_node_id()
        self.assertIsInstance(node_id, str)
        self.assertGreater(len(node_id), 0)

    def test_contains_hostname(self):
        import socket
        node_id = derive_node_id()
        hostname = socket.gethostname()
        self.assertIn(hostname, node_id)

    def test_stable_across_calls(self):
        a = derive_node_id()
        b = derive_node_id()
        self.assertEqual(a, b)

    def test_with_repo_root(self):
        node_id = derive_node_id(REPO)
        self.assertIsInstance(node_id, str)
        self.assertGreater(len(node_id), 0)


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

class RegisterTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_register_returns_ok(self):
        result = self.relay.register("node-a", "sess-1", alias="codex")
        self.assertTrue(result["ok"])
        self.assertEqual(result["alias"], "codex")
        self.assertEqual(result["node_id"], "node-a")

    def test_register_creates_inbox(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        msgs = self.relay.poll_inbox("node-a", "sess-1")
        self.assertEqual(msgs, [])

    def test_register_same_alias_same_session_refreshes_lease(self):
        self.relay.register("node-a", "sess-1", alias="codex")
        # Advance the lease backward
        self.relay._tick_lease("codex", 100)
        before_last_seen = self.relay._leases["codex"].last_seen
        import time
        time.sleep(0.01)
        self.relay.register("node-a", "sess-1", alias="codex")
        after_last_seen = self.relay._leases["codex"].last_seen
        self.assertGreater(after_last_seen, before_last_seen)

    def test_register_same_alias_different_session_replaces(self):
        """Managed session restart: same alias, new session_id."""
        self.relay.register("node-a", "sess-old", alias="kimi")
        self.relay.register("node-a", "sess-new", alias="kimi")
        peers = self.relay.list_peers()
        aliases = [p["alias"] for p in peers]
        self.assertEqual(aliases.count("kimi"), 1)
        self.assertEqual(self.relay._leases["kimi"].session_id, "sess-new")

    def test_register_alias_conflict_different_node_raises(self):
        self.relay.register("node-a", "sess-1", alias="storm")
        with self.assertRaises(RelayError) as ctx:
            self.relay.register("node-b", "sess-2", alias="storm")
        self.assertEqual(ctx.exception.code, RELAY_ERR_ALIAS_CONFLICT)

    def test_register_includes_node_id_in_registry(self):
        self.relay.register("node-a", "sess-1", alias="opencode", client_type="opencode")
        peers = self.relay.list_peers(include_dead=True)
        self.assertEqual(len(peers), 1)
        self.assertEqual(peers[0]["node_id"], "node-a")
        self.assertEqual(peers[0]["client_type"], "opencode")


# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

class HeartbeatTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_heartbeat_refreshes_last_seen(self):
        import time
        self.relay.register("node-a", "sess-1", alias="codex")
        self.relay._tick_lease("codex", 100)
        before = self.relay._leases["codex"].last_seen
        time.sleep(0.01)
        result = self.relay.heartbeat("node-a", "sess-1")
        self.assertTrue(result["ok"])
        self.assertGreater(result["last_seen"], before)

    def test_heartbeat_unknown_raises(self):
        with self.assertRaises(RelayError) as ctx:
            self.relay.heartbeat("node-x", "sess-x")
        self.assertEqual(ctx.exception.code, RELAY_ERR_UNKNOWN_ALIAS)

    def test_heartbeat_prevents_lease_expiry(self):
        """A sequence of heartbeats keeps the lease alive beyond one TTL."""
        self.relay.register("node-a", "sess-1", alias="codex", ttl=0.05)
        import time
        self.relay.heartbeat("node-a", "sess-1")
        time.sleep(0.02)
        self.relay.heartbeat("node-a", "sess-1")
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 1)


# ---------------------------------------------------------------------------
# list_peers
# ---------------------------------------------------------------------------

class ListPeersTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_list_peers_empty(self):
        self.assertEqual(self.relay.list_peers(), [])

    def test_list_peers_returns_alive_only_by_default(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=0.01)
        import time
        time.sleep(0.05)
        self.assertEqual(self.relay.list_peers(), [])

    def test_list_peers_include_dead(self):
        self.relay.register("node-a", "sess-1", alias="codex", ttl=0.01)
        import time
        time.sleep(0.05)
        peers = self.relay.list_peers(include_dead=True)
        self.assertEqual(len(peers), 1)
        self.assertFalse(peers[0]["alive"])

    def test_list_peers_row_shape(self):
        self.relay.register("node-a", "sess-1", alias="codex", client_type="codex")
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 1)
        row = peers[0]
        for key in ("node_id", "session_id", "alias", "client_type",
                    "registered_at", "last_seen", "ttl", "alive"):
            self.assertIn(key, row, f"missing key: {key}")
        self.assertTrue(row["alive"])


# ---------------------------------------------------------------------------
# send / poll_inbox / peek_inbox
# ---------------------------------------------------------------------------

class SendPollTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-a", alias="alice")
        self.relay.register("node-b", "sess-b", alias="bob")

    def test_send_returns_ok(self):
        result = self.relay.send("alice", "bob", "hello")
        self.assertTrue(result["ok"])
        self.assertIn("ts", result)
        self.assertIn("message_id", result)

    def test_poll_inbox_drains_messages(self):
        self.relay.send("alice", "bob", "msg1")
        self.relay.send("alice", "bob", "msg2")
        msgs = self.relay.poll_inbox("node-b", "sess-b")
        self.assertEqual(len(msgs), 2)
        contents = [m["content"] for m in msgs]
        self.assertIn("msg1", contents)
        self.assertIn("msg2", contents)

    def test_poll_inbox_empties_after_drain(self):
        self.relay.send("alice", "bob", "msg1")
        self.relay.poll_inbox("node-b", "sess-b")
        msgs = self.relay.poll_inbox("node-b", "sess-b")
        self.assertEqual(msgs, [])

    def test_peek_inbox_is_non_destructive(self):
        self.relay.send("alice", "bob", "msg1")
        peek1 = self.relay.peek_inbox("node-b", "sess-b")
        peek2 = self.relay.peek_inbox("node-b", "sess-b")
        self.assertEqual(len(peek1), 1)
        self.assertEqual(len(peek2), 1)
        poll = self.relay.poll_inbox("node-b", "sess-b")
        self.assertEqual(len(poll), 1)

    def test_peek_and_poll_return_same_shape(self):
        self.relay.send("alice", "bob", "hello")
        peek = self.relay.peek_inbox("node-b", "sess-b")
        poll = self.relay.poll_inbox("node-b", "sess-b")
        self.assertEqual(peek[0]["content"], poll[0]["content"])
        self.assertEqual(peek[0]["from_alias"], poll[0]["from_alias"])
        self.assertEqual(peek[0]["to_alias"], poll[0]["to_alias"])

    def test_send_records_from_and_to_aliases(self):
        self.relay.send("alice", "bob", "hi")
        msg = self.relay.poll_inbox("node-b", "sess-b")[0]
        self.assertEqual(msg["from_alias"], "alice")
        self.assertEqual(msg["to_alias"], "bob")
        self.assertEqual(msg["content"], "hi")

    def test_send_to_self_delivers(self):
        self.relay.send("alice", "alice", "self-note")
        msgs = self.relay.poll_inbox("node-a", "sess-a")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "self-note")

    def test_poll_empty_inbox_returns_empty_list(self):
        msgs = self.relay.poll_inbox("node-a", "sess-a")
        self.assertEqual(msgs, [])


# ---------------------------------------------------------------------------
# Dead-letter
# ---------------------------------------------------------------------------

class DeadLetterTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-a", alias="alice")

    def test_send_unknown_alias_raises_and_dead_letters(self):
        with self.assertRaises(RelayError) as ctx:
            self.relay.send("alice", "nobody", "hello")
        self.assertEqual(ctx.exception.code, RELAY_ERR_UNKNOWN_ALIAS)
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["to_alias"], "nobody")
        self.assertEqual(dl[0]["reason"], "unknown_alias")

    def test_send_dead_recipient_raises_and_dead_letters(self):
        self.relay.register("node-b", "sess-b", alias="bob", ttl=0.01)
        import time
        time.sleep(0.05)
        with self.assertRaises(RelayError) as ctx:
            self.relay.send("alice", "bob", "too late")
        self.assertEqual(ctx.exception.code, RELAY_ERR_RECIPIENT_DEAD)
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["reason"], "recipient_dead")

    def test_dead_letter_is_non_destructive(self):
        with self.assertRaises(RelayError):
            self.relay.send("alice", "nobody", "hello")
        dl1 = self.relay.dead_letter()
        dl2 = self.relay.dead_letter()
        self.assertEqual(len(dl1), len(dl2))

    def test_dead_letter_entry_shape(self):
        with self.assertRaises(RelayError):
            self.relay.send("alice", "nobody", "oops")
        entry = self.relay.dead_letter()[0]
        for key in ("ts", "message_id", "from_alias", "to_alias", "content", "reason"):
            self.assertIn(key, entry, f"missing key: {key}")

    def test_relay_error_to_dict(self):
        err = RelayError("test_code", "test message")
        d = err.to_dict()
        self.assertFalse(d["ok"])
        self.assertEqual(d["error_code"], "test_code")
        self.assertEqual(d["error"], "test message")


# ---------------------------------------------------------------------------
# RegistrationLease is_alive
# ---------------------------------------------------------------------------

class LeaseLivenessTests(unittest.TestCase):
    def test_fresh_lease_is_alive(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", alias="codex")
        self.assertTrue(self.relay._leases["codex"].is_alive())

    def test_expired_lease_is_dead(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", alias="codex", ttl=0.01)
        import time
        time.sleep(0.05)
        self.assertFalse(self.relay._leases["codex"].is_alive())

    def test_tick_lease_advances_expiry(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", alias="codex", ttl=10.0)
        self.relay._tick_lease("codex", 20.0)
        self.assertFalse(self.relay._leases["codex"].is_alive())


if __name__ == "__main__":
    unittest.main()
