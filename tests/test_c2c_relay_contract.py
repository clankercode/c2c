"""Contract tests for c2c_relay_contract — Phase 1 in-process relay.

Tests exercise:
  - derive_node_id: stability and format
  - InMemoryRelay.register: same-session refresh, managed restart (new session_id),
    alias conflict between different nodes
  - InMemoryRelay.heartbeat: refreshes last_seen, error on unknown session
  - InMemoryRelay.list_peers: alive/dead filtering, include_dead flag
  - InMemoryRelay.send: happy path, unknown alias → dead-letter, dead lease →
    dead-letter
  - InMemoryRelay.poll_inbox: drain semantics (exactly-once), empty after drain
  - InMemoryRelay.peek_inbox: non-consuming snapshot
  - InMemoryRelay.dead_letter: non-consuming list
  - Two-node scenario: node-a sends to node-b, node-b polls
  - Lease expiry via _tick_lease helper
"""
from __future__ import annotations

import threading
import time
import unittest

from c2c_relay_contract import (
    RELAY_ERR_ALIAS_CONFLICT,
    RELAY_ERR_RECIPIENT_DEAD,
    RELAY_ERR_UNKNOWN_ALIAS,
    InMemoryRelay,
    RegistrationLease,
    RelayError,
    derive_node_id,
)


# ---------------------------------------------------------------------------
# derive_node_id
# ---------------------------------------------------------------------------

class DeriveNodeIdTests(unittest.TestCase):
    def test_returns_string(self):
        nid = derive_node_id()
        self.assertIsInstance(nid, str)

    def test_non_empty(self):
        nid = derive_node_id()
        self.assertTrue(len(nid) > 0)

    def test_format_has_hyphen(self):
        """node_id must contain at least one hyphen separating hostname from suffix."""
        nid = derive_node_id()
        self.assertIn("-", nid)

    def test_stable_across_calls(self):
        """Two calls in the same process must return the same value."""
        a = derive_node_id()
        b = derive_node_id()
        self.assertEqual(a, b)

    def test_fallback_ends_with_local_or_hash(self):
        """Falls back to <hostname>-local or <hostname>-<8chars> depending on remote."""
        nid = derive_node_id()
        suffix = nid.rsplit("-", 1)[-1]
        self.assertTrue(
            suffix == "local" or len(suffix) == 8,
            f"unexpected suffix {suffix!r} in node_id {nid!r}",
        )


# ---------------------------------------------------------------------------
# RegistrationLease
# ---------------------------------------------------------------------------

class RegistrationLeaseTests(unittest.TestCase):
    def _make(self, ttl=300.0, last_seen_offset=0.0) -> RegistrationLease:
        lease = RegistrationLease(
            node_id="node-a",
            session_id="sess-1",
            alias="alpha",
            ttl=ttl,
        )
        lease.last_seen += last_seen_offset
        return lease

    def test_alive_when_fresh(self):
        lease = self._make(ttl=300.0)
        self.assertTrue(lease.is_alive())

    def test_dead_after_ttl(self):
        lease = self._make(ttl=1.0, last_seen_offset=-10.0)
        self.assertFalse(lease.is_alive())

    def test_alive_exactly_at_expiry(self):
        now = time.time()
        lease = self._make(ttl=10.0)
        lease.last_seen = now - 10.0
        # exactly at boundary → alive (>=)
        self.assertTrue(lease.is_alive(now=now))

    def test_dead_one_second_past_ttl(self):
        now = time.time()
        lease = self._make(ttl=10.0)
        lease.last_seen = now - 11.0
        self.assertFalse(lease.is_alive(now=now))

    def test_to_dict_fields(self):
        lease = self._make()
        d = lease.to_dict()
        for key in ("node_id", "session_id", "alias", "client_type",
                    "registered_at", "last_seen", "ttl", "alive"):
            self.assertIn(key, d)

    def test_to_dict_alive_true_when_fresh(self):
        lease = self._make()
        self.assertTrue(lease.to_dict()["alive"])

    def test_to_dict_alive_false_when_expired(self):
        lease = self._make(ttl=1.0, last_seen_offset=-100.0)
        self.assertFalse(lease.to_dict()["alive"])


# ---------------------------------------------------------------------------
# InMemoryRelay — register
# ---------------------------------------------------------------------------

class RegisterTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_register_returns_ok(self):
        result = self.relay.register("node-a", "sess-1", "alpha")
        self.assertTrue(result["ok"])
        self.assertEqual(result["alias"], "alpha")
        self.assertEqual(result["node_id"], "node-a")

    def test_same_session_reregister_refreshes(self):
        self.relay.register("node-a", "sess-1", "alpha")
        result = self.relay.register("node-a", "sess-1", "alpha")
        self.assertTrue(result["ok"])

    def test_managed_restart_new_session_id(self):
        """Same alias, different session_id (managed restart) → replaces old entry."""
        self.relay.register("node-a", "sess-old", "alpha")
        result = self.relay.register("node-a", "sess-new", "alpha")
        self.assertTrue(result["ok"])
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 1)
        self.assertEqual(peers[0]["session_id"], "sess-new")

    def test_alias_conflict_different_node(self):
        """Different node+session trying to take an alive alias → conflict error."""
        self.relay.register("node-a", "sess-1", "alpha")
        with self.assertRaises(RelayError) as ctx:
            self.relay.register("node-b", "sess-2", "alpha")
        self.assertEqual(ctx.exception.code, RELAY_ERR_ALIAS_CONFLICT)

    def test_alias_conflict_same_node_different_session(self):
        """Same node, different session_id → this is a managed restart, allowed."""
        self.relay.register("node-a", "sess-1", "alpha")
        # Different session on same node is treated as managed restart
        result = self.relay.register("node-a", "sess-2", "alpha")
        self.assertTrue(result["ok"])

    def test_expired_alias_can_be_taken_by_new_node(self):
        """Once a lease expires, a different node may register the same alias."""
        self.relay.register("node-a", "sess-1", "alpha", ttl=1.0)
        self.relay._tick_lease("alpha", 10.0)  # expire the lease
        result = self.relay.register("node-b", "sess-2", "alpha")
        self.assertTrue(result["ok"])

    def test_inbox_created_on_register(self):
        self.relay.register("node-a", "sess-1", "alpha")
        # Inbox should exist and be empty
        msgs = self.relay.peek_inbox("node-a", "sess-1")
        self.assertEqual(msgs, [])

    def test_second_register_does_not_drop_inbox(self):
        """Re-registration with same session must not lose queued messages."""
        self.relay.register("node-a", "sess-1", "alpha")
        self.relay.register("node-b", "sess-2", "beta")
        self.relay.send("beta", "alpha", "hello")
        # Re-register same session
        self.relay.register("node-a", "sess-1", "alpha")
        msgs = self.relay.peek_inbox("node-a", "sess-1")
        self.assertEqual(len(msgs), 1)

    def test_client_type_stored(self):
        self.relay.register("node-a", "sess-1", "alpha", client_type="codex")
        peers = self.relay.list_peers()
        self.assertEqual(peers[0]["client_type"], "codex")


# ---------------------------------------------------------------------------
# InMemoryRelay — heartbeat
# ---------------------------------------------------------------------------

class HeartbeatTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_heartbeat_returns_ok(self):
        self.relay.register("node-a", "sess-1", "alpha")
        result = self.relay.heartbeat("node-a", "sess-1")
        self.assertTrue(result["ok"])
        self.assertEqual(result["alias"], "alpha")

    def test_heartbeat_updates_last_seen(self):
        self.relay.register("node-a", "sess-1", "alpha")
        self.relay._tick_lease("alpha", 100.0)  # push last_seen back
        before = self.relay.list_peers()[0]["last_seen"]
        self.relay.heartbeat("node-a", "sess-1")
        after = self.relay.list_peers()[0]["last_seen"]
        self.assertGreater(after, before)

    def test_heartbeat_unknown_session_raises(self):
        with self.assertRaises(RelayError) as ctx:
            self.relay.heartbeat("node-a", "nonexistent")
        self.assertEqual(ctx.exception.code, RELAY_ERR_UNKNOWN_ALIAS)

    def test_heartbeat_can_revive_expired_lease(self):
        """Heartbeating an expired (but still registered) session refreshes liveness."""
        self.relay.register("node-a", "sess-1", "alpha")
        self.relay._tick_lease("alpha", 1000.0)  # well past TTL
        self.assertFalse(self.relay.list_peers(include_dead=True)[0]["alive"])
        self.relay.heartbeat("node-a", "sess-1")
        self.assertTrue(self.relay.list_peers()[0]["alive"])


# ---------------------------------------------------------------------------
# InMemoryRelay — list_peers
# ---------------------------------------------------------------------------

class ListPeersTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()

    def test_empty_returns_empty_list(self):
        self.assertEqual(self.relay.list_peers(), [])

    def test_shows_alive_peers(self):
        self.relay.register("node-a", "sess-1", "alpha")
        self.relay.register("node-b", "sess-2", "beta")
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 2)

    def test_excludes_expired_by_default(self):
        self.relay.register("node-a", "sess-1", "alpha", ttl=1.0)
        self.relay._tick_lease("alpha", 10.0)
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 0)

    def test_include_dead_flag(self):
        self.relay.register("node-a", "sess-1", "alpha", ttl=1.0)
        self.relay._tick_lease("alpha", 10.0)
        peers = self.relay.list_peers(include_dead=True)
        self.assertEqual(len(peers), 1)
        self.assertFalse(peers[0]["alive"])

    def test_peer_dict_has_expected_fields(self):
        self.relay.register("node-a", "sess-1", "alpha")
        peer = self.relay.list_peers()[0]
        for key in ("node_id", "session_id", "alias", "client_type",
                    "registered_at", "last_seen", "ttl", "alive"):
            self.assertIn(key, peer)


# ---------------------------------------------------------------------------
# InMemoryRelay — send
# ---------------------------------------------------------------------------

class SendTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", "alice")
        self.relay.register("node-b", "sess-2", "bob")

    def test_send_returns_ok(self):
        result = self.relay.send("alice", "bob", "hello")
        self.assertTrue(result["ok"])
        self.assertIn("ts", result)
        self.assertIn("message_id", result)

    def test_send_to_unknown_alias_raises_and_dead_letters(self):
        with self.assertRaises(RelayError) as ctx:
            self.relay.send("alice", "nobody", "hey")
        self.assertEqual(ctx.exception.code, RELAY_ERR_UNKNOWN_ALIAS)
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["to_alias"], "nobody")
        self.assertEqual(dl[0]["reason"], "unknown_alias")

    def test_send_to_dead_recipient_raises_and_dead_letters(self):
        self.relay._tick_lease("bob", 1000.0)  # expire bob
        with self.assertRaises(RelayError) as ctx:
            self.relay.send("alice", "bob", "hey")
        self.assertEqual(ctx.exception.code, RELAY_ERR_RECIPIENT_DEAD)
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["reason"], "recipient_dead")

    def test_send_self_message(self):
        """Sender and recipient can be the same alias."""
        result = self.relay.send("alice", "alice", "talking to myself")
        self.assertTrue(result["ok"])
        msgs = self.relay.poll_inbox("node-a", "sess-1")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "talking to myself")

    def test_send_appends_to_inbox(self):
        self.relay.send("alice", "bob", "msg1")
        self.relay.send("alice", "bob", "msg2")
        msgs = self.relay.peek_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs), 2)

    def test_send_message_contains_expected_fields(self):
        self.relay.send("alice", "bob", "content here")
        msgs = self.relay.peek_inbox("node-b", "sess-2")
        msg = msgs[0]
        for key in ("message_id", "from_alias", "to_alias", "content", "ts"):
            self.assertIn(key, msg)
        self.assertEqual(msg["from_alias"], "alice")
        self.assertEqual(msg["to_alias"], "bob")
        self.assertEqual(msg["content"], "content here")

    def test_send_stable_message_id(self):
        """Caller-supplied message_id is preserved."""
        self.relay.send("alice", "bob", "hello", message_id="my-id-123")
        msgs = self.relay.peek_inbox("node-b", "sess-2")
        self.assertEqual(msgs[0]["message_id"], "my-id-123")

    def test_send_auto_generates_message_id(self):
        result = self.relay.send("alice", "bob", "auto id")
        self.assertIsInstance(result["message_id"], str)
        self.assertTrue(len(result["message_id"]) > 0)

    def test_error_to_dict(self):
        try:
            self.relay.send("alice", "nobody", "hey")
        except RelayError as e:
            d = e.to_dict()
            self.assertFalse(d["ok"])
            self.assertIn("error_code", d)
            self.assertIn("error", d)


# ---------------------------------------------------------------------------
# InMemoryRelay — poll_inbox
# ---------------------------------------------------------------------------

class PollInboxTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", "alice")
        self.relay.register("node-b", "sess-2", "bob")

    def test_poll_returns_messages(self):
        self.relay.send("alice", "bob", "hello")
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "hello")

    def test_poll_drains_inbox(self):
        self.relay.send("alice", "bob", "msg1")
        self.relay.poll_inbox("node-b", "sess-2")
        msgs2 = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(msgs2, [])

    def test_poll_exactly_once(self):
        """Each message is returned exactly once across repeated polls."""
        self.relay.send("alice", "bob", "a")
        self.relay.send("alice", "bob", "b")
        first = self.relay.poll_inbox("node-b", "sess-2")
        second = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(len(first), 2)
        self.assertEqual(len(second), 0)

    def test_poll_empty_inbox_returns_empty_list(self):
        result = self.relay.poll_inbox("node-a", "sess-1")
        self.assertEqual(result, [])

    def test_poll_unregistered_session_returns_empty(self):
        result = self.relay.poll_inbox("node-x", "nonexistent")
        self.assertEqual(result, [])

    def test_poll_multiple_messages_ordered(self):
        """Messages are returned in send order."""
        for i in range(5):
            self.relay.send("alice", "bob", f"msg-{i}")
        msgs = self.relay.poll_inbox("node-b", "sess-2")
        contents = [m["content"] for m in msgs]
        self.assertEqual(contents, [f"msg-{i}" for i in range(5)])


# ---------------------------------------------------------------------------
# InMemoryRelay — peek_inbox
# ---------------------------------------------------------------------------

class PeekInboxTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", "alice")
        self.relay.register("node-b", "sess-2", "bob")

    def test_peek_returns_messages(self):
        self.relay.send("alice", "bob", "hello")
        msgs = self.relay.peek_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs), 1)

    def test_peek_does_not_consume(self):
        self.relay.send("alice", "bob", "hello")
        self.relay.peek_inbox("node-b", "sess-2")
        msgs2 = self.relay.peek_inbox("node-b", "sess-2")
        self.assertEqual(len(msgs2), 1)

    def test_peek_then_poll(self):
        self.relay.send("alice", "bob", "hi")
        self.relay.peek_inbox("node-b", "sess-2")  # should not drain
        polled = self.relay.poll_inbox("node-b", "sess-2")
        self.assertEqual(len(polled), 1)

    def test_peek_returns_copy(self):
        """Mutating the returned list must not affect the relay's internal state."""
        self.relay.send("alice", "bob", "hi")
        msgs = self.relay.peek_inbox("node-b", "sess-2")
        msgs.clear()
        still_there = self.relay.peek_inbox("node-b", "sess-2")
        self.assertEqual(len(still_there), 1)


# ---------------------------------------------------------------------------
# InMemoryRelay — dead_letter
# ---------------------------------------------------------------------------

class DeadLetterTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", "alice")

    def test_dead_letter_empty_initially(self):
        self.assertEqual(self.relay.dead_letter(), [])

    def test_dead_letter_contains_undelivered_messages(self):
        try:
            self.relay.send("alice", "ghost", "hello")
        except RelayError:
            pass
        dl = self.relay.dead_letter()
        self.assertEqual(len(dl), 1)

    def test_dead_letter_is_non_consuming(self):
        try:
            self.relay.send("alice", "ghost", "msg1")
        except RelayError:
            pass
        self.relay.dead_letter()
        dl2 = self.relay.dead_letter()
        self.assertEqual(len(dl2), 1)

    def test_dead_letter_fields(self):
        try:
            self.relay.send("alice", "ghost", "content")
        except RelayError:
            pass
        entry = self.relay.dead_letter()[0]
        for key in ("ts", "message_id", "from_alias", "to_alias", "content", "reason"):
            self.assertIn(key, entry)

    def test_dead_letter_accumulates(self):
        for i in range(3):
            try:
                self.relay.send("alice", f"ghost-{i}", f"msg-{i}")
            except RelayError:
                pass
        self.assertEqual(len(self.relay.dead_letter()), 3)


# ---------------------------------------------------------------------------
# Lease expiry via _tick_lease
# ---------------------------------------------------------------------------

class TickLeaseTests(unittest.TestCase):
    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register("node-a", "sess-1", "alpha", ttl=300.0)

    def test_tick_lease_makes_session_dead(self):
        self.relay._tick_lease("alpha", 400.0)
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 0)

    def test_tick_lease_unknown_alias_noop(self):
        # Must not raise
        self.relay._tick_lease("nonexistent", 999.0)

    def test_tick_lease_partial_expiry_still_alive(self):
        self.relay._tick_lease("alpha", 100.0)  # 300 - 100 = 200s remaining
        peers = self.relay.list_peers()
        self.assertEqual(len(peers), 1)

    def test_dead_session_cannot_receive(self):
        self.relay.register("node-b", "sess-2", "beta")
        self.relay._tick_lease("beta", 1000.0)  # expire beta
        with self.assertRaises(RelayError) as ctx:
            self.relay.send("alpha", "beta", "should fail")
        self.assertEqual(ctx.exception.code, RELAY_ERR_RECIPIENT_DEAD)


# ---------------------------------------------------------------------------
# Two-node scenario
# ---------------------------------------------------------------------------

class TwoNodeScenarioTests(unittest.TestCase):
    """Simulate two separate machines: node-laptop and node-server."""

    NODE_A = "node-laptop-abc12345"
    NODE_B = "node-server-def67890"

    def setUp(self):
        self.relay = InMemoryRelay()
        self.relay.register(self.NODE_A, "session-a", "claude-laptop",
                            client_type="claude-code")
        self.relay.register(self.NODE_B, "session-b", "codex-server",
                            client_type="codex")

    def test_cross_node_message_delivery(self):
        """node-a sends to node-b; node-b polls and receives exactly once."""
        self.relay.send("claude-laptop", "codex-server", "hello from laptop")
        msgs = self.relay.poll_inbox(self.NODE_B, "session-b")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "hello from laptop")
        self.assertEqual(msgs[0]["from_alias"], "claude-laptop")

    def test_cross_node_reply(self):
        """Round-trip: A→B and B→A both succeed."""
        self.relay.send("claude-laptop", "codex-server", "ping")
        self.relay.poll_inbox(self.NODE_B, "session-b")  # drain
        self.relay.send("codex-server", "claude-laptop", "pong")
        reply = self.relay.poll_inbox(self.NODE_A, "session-a")
        self.assertEqual(len(reply), 1)
        self.assertEqual(reply[0]["content"], "pong")

    def test_node_a_inbox_unaffected_by_b_messages(self):
        """Messages to B do not appear in A's inbox."""
        self.relay.send("claude-laptop", "codex-server", "for B only")
        a_msgs = self.relay.poll_inbox(self.NODE_A, "session-a")
        self.assertEqual(a_msgs, [])

    def test_list_peers_shows_both_nodes(self):
        peers = self.relay.list_peers()
        aliases = {p["alias"] for p in peers}
        self.assertEqual(aliases, {"claude-laptop", "codex-server"})
        nodes = {p["node_id"] for p in peers}
        self.assertEqual(nodes, {self.NODE_A, self.NODE_B})

    def test_node_isolation_alias_conflict(self):
        """A third machine cannot steal an alias held by an alive session."""
        with self.assertRaises(RelayError) as ctx:
            self.relay.register("node-interloper", "sess-x", "codex-server")
        self.assertEqual(ctx.exception.code, RELAY_ERR_ALIAS_CONFLICT)

    def test_managed_restart_preserves_message_delivery(self):
        """After a managed restart (new session_id), new inbox receives messages."""
        self.relay.send("claude-laptop", "codex-server", "pre-restart")
        # codex-server restarts with a new session_id
        self.relay.register(self.NODE_B, "session-b-new", "codex-server")
        # Send a post-restart message
        self.relay.send("claude-laptop", "codex-server", "post-restart")
        # New inbox should have the post-restart message
        new_msgs = self.relay.poll_inbox(self.NODE_B, "session-b-new")
        contents = [m["content"] for m in new_msgs]
        self.assertIn("post-restart", contents)

    def test_heartbeat_from_node_b(self):
        """node-b can heartbeat and remain alive."""
        result = self.relay.heartbeat(self.NODE_B, "session-b")
        self.assertTrue(result["ok"])
        self.assertEqual(result["alias"], "codex-server")

    def test_expired_node_a_does_not_block_new_registration(self):
        """After node-a's lease expires, another session can take claude-laptop."""
        self.relay._tick_lease("claude-laptop", 10000.0)
        result = self.relay.register("node-new", "sess-new", "claude-laptop")
        self.assertTrue(result["ok"])


# ---------------------------------------------------------------------------
# Thread safety smoke test
# ---------------------------------------------------------------------------

class ThreadSafetyTests(unittest.TestCase):
    def test_concurrent_sends_all_delivered(self):
        """Multiple threads sending to the same inbox must not lose messages."""
        relay = InMemoryRelay()
        relay.register("node-a", "sess-sender", "sender")
        relay.register("node-b", "sess-recv", "receiver")

        n = 50
        errors = []

        def send_n(start):
            for i in range(start, start + n):
                try:
                    relay.send("sender", "receiver", f"msg-{i}")
                except Exception as e:
                    errors.append(e)

        threads = [threading.Thread(target=send_n, args=(i * n,)) for i in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(errors, [])
        msgs = relay.poll_inbox("node-b", "sess-recv")
        self.assertEqual(len(msgs), 4 * n)

    def test_concurrent_polls_total_count_correct(self):
        """Concurrent polls must drain exactly once across all threads."""
        relay = InMemoryRelay()
        relay.register("node-a", "sess-sender", "sender")
        relay.register("node-b", "sess-recv", "receiver")

        total = 100
        for i in range(total):
            relay.send("sender", "receiver", f"msg-{i}")

        collected = []
        lock = threading.Lock()

        def poll():
            msgs = relay.poll_inbox("node-b", "sess-recv")
            with lock:
                collected.extend(msgs)

        threads = [threading.Thread(target=poll) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Each message delivered exactly once
        self.assertEqual(len(collected), total)


if __name__ == "__main__":
    unittest.main()
