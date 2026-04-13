"""HTTP integration tests for c2c_relay_server — Phase 2 relay.

Spins up a real localhost server on an ephemeral port in each test class
setUp, exercises the HTTP API end-to-end, and verifies JSON responses.

Tests cover:
  - /health (no auth required)
  - auth rejection (missing, wrong, correct token)
  - POST /register → 200 with ok
  - POST /heartbeat → 200 / 409 on unknown session
  - GET+POST /list → peers
  - POST /send → 200; 409 on unknown alias; 409 on dead recipient
  - POST /poll_inbox → drain semantics
  - POST /peek_inbox → non-consuming
  - GET /dead_letter → dead-letter entries
  - 400 on missing required fields
  - 404 on unknown path
  - Concurrent requests do not lose messages
"""
from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
import unittest

from c2c_relay_contract import InMemoryRelay
from c2c_relay_server import start_server_thread


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _post(url: str, payload: dict, token: str | None = None) -> tuple[int, dict]:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        finally:
            e.close()


def _get(url: str, token: str | None = None) -> tuple[int, dict]:
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        finally:
            e.close()


# ---------------------------------------------------------------------------
# Base class: spin up server once per test class
# ---------------------------------------------------------------------------

class _RelayServerTestBase(unittest.TestCase):
    TOKEN = "test-secret-token"

    @classmethod
    def setUpClass(cls):
        relay = InMemoryRelay()
        server, thread = start_server_thread(
            host="127.0.0.1",
            port=0,
            token=cls.TOKEN,
            relay=relay,
        )
        cls._server = server
        cls._thread = thread
        cls._relay = relay
        _, port = server.server_address
        cls._base = f"http://127.0.0.1:{port}"

    @classmethod
    def tearDownClass(cls):
        cls._server.shutdown()
        cls._thread.join(timeout=2)

    def url(self, path: str) -> str:
        return self._base + path

    def post(self, path: str, payload: dict) -> tuple[int, dict]:
        return _post(self.url(path), payload, token=self.TOKEN)

    def get(self, path: str) -> tuple[int, dict]:
        return _get(self.url(path), token=self.TOKEN)


# ---------------------------------------------------------------------------
# /health
# ---------------------------------------------------------------------------

class HealthTests(_RelayServerTestBase):
    def test_health_no_auth_required(self):
        status, body = _get(self.url("/health"))  # no token
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_health_with_auth_also_ok(self):
        status, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class AuthTests(_RelayServerTestBase):
    def test_missing_token_returns_401(self):
        status, body = _post(self.url("/list"), {})  # no token
        self.assertEqual(status, 401)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error_code"], "unauthorized")

    def test_wrong_token_returns_401(self):
        status, body = _post(self.url("/list"), {}, token="wrong-token")
        self.assertEqual(status, 401)
        self.assertFalse(body["ok"])

    def test_correct_token_returns_200(self):
        status, body = self.post("/list", {})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_no_token_server_allows_all(self):
        """A server started without a token allows unauthenticated requests."""
        relay = InMemoryRelay()
        server, thread = start_server_thread("127.0.0.1", 0, token=None, relay=relay)
        try:
            _, port = server.server_address
            base = f"http://127.0.0.1:{port}"
            status, body = _post(base + "/list", {})
            self.assertEqual(status, 200)
        finally:
            server.shutdown()
            thread.join(timeout=2)


# ---------------------------------------------------------------------------
# /register
# ---------------------------------------------------------------------------

class RegisterTests(_RelayServerTestBase):
    def test_register_returns_ok(self):
        status, body = self.post("/register", {
            "node_id": "node-a", "session_id": "sess-1", "alias": "alice"
        })
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["alias"], "alice")

    def test_register_missing_fields_returns_400(self):
        status, body = self.post("/register", {"node_id": "node-a"})
        self.assertEqual(status, 400)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error_code"], "bad_request")

    def test_register_alias_conflict_returns_409(self):
        self.post("/register", {
            "node_id": "node-a", "session_id": "sess-1", "alias": "conflict-alias"
        })
        status, body = self.post("/register", {
            "node_id": "node-b", "session_id": "sess-2", "alias": "conflict-alias"
        })
        self.assertEqual(status, 409)
        self.assertFalse(body["ok"])
        self.assertIn("alias_conflict", body["error_code"])

    def test_register_with_client_type(self):
        status, body = self.post("/register", {
            "node_id": "node-ct", "session_id": "sess-ct",
            "alias": "ct-test", "client_type": "codex",
        })
        self.assertEqual(status, 200)
        # Verify client_type stored by listing peers
        _, list_body = self.get("/list")
        peer = next(p for p in list_body["peers"] if p["alias"] == "ct-test")
        self.assertEqual(peer["client_type"], "codex")

    def test_register_with_ttl(self):
        status, body = self.post("/register", {
            "node_id": "node-ttl", "session_id": "sess-ttl",
            "alias": "ttl-test", "ttl": 600.0,
        })
        self.assertEqual(status, 200)
        _, list_body = self.get("/list")
        peer = next(p for p in list_body["peers"] if p["alias"] == "ttl-test")
        self.assertAlmostEqual(peer["ttl"], 600.0, delta=1.0)


# ---------------------------------------------------------------------------
# /heartbeat
# ---------------------------------------------------------------------------

class HeartbeatTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-hb", "sess-hb", "hb-peer")

    def test_heartbeat_returns_ok(self):
        status, body = self.post("/heartbeat", {
            "node_id": "node-hb", "session_id": "sess-hb"
        })
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["alias"], "hb-peer")

    def test_heartbeat_missing_fields_returns_400(self):
        status, body = self.post("/heartbeat", {"node_id": "node-hb"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error_code"], "bad_request")

    def test_heartbeat_unknown_session_returns_409(self):
        status, body = self.post("/heartbeat", {
            "node_id": "node-hb", "session_id": "nonexistent"
        })
        self.assertEqual(status, 409)
        self.assertFalse(body["ok"])
        self.assertIn("unknown_alias", body["error_code"])


# ---------------------------------------------------------------------------
# /list
# ---------------------------------------------------------------------------

class ListTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-list", "sess-list-a", "list-peer-a")
        cls._relay.register("node-list", "sess-list-b", "list-peer-b")

    def test_get_list_returns_peers(self):
        status, body = self.get("/list")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("peers", body)
        aliases = {p["alias"] for p in body["peers"]}
        self.assertIn("list-peer-a", aliases)
        self.assertIn("list-peer-b", aliases)

    def test_post_list_returns_peers(self):
        status, body = self.post("/list", {})
        self.assertEqual(status, 200)
        self.assertIn("peers", body)

    def test_list_peer_has_expected_fields(self):
        _, body = self.get("/list")
        peer = next(p for p in body["peers"] if p["alias"] == "list-peer-a")
        for key in ("node_id", "session_id", "alias", "client_type",
                    "registered_at", "last_seen", "ttl", "alive"):
            self.assertIn(key, peer)


# ---------------------------------------------------------------------------
# /send
# ---------------------------------------------------------------------------

class SendTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-send-a", "sess-send-a", "send-alice")
        cls._relay.register("node-send-b", "sess-send-b", "send-bob")

    def test_send_returns_ok(self):
        status, body = self.post("/send", {
            "from_alias": "send-alice",
            "to_alias": "send-bob",
            "content": "hello from alice",
        })
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("message_id", body)
        self.assertIn("ts", body)

    def test_send_unknown_alias_returns_409_dead_letters(self):
        status, body = self.post("/send", {
            "from_alias": "send-alice",
            "to_alias": "nobody",
            "content": "hello ghost",
        })
        self.assertEqual(status, 409)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error_code"], "unknown_alias")
        # Check dead-letter has this entry
        _, dl_body = self.get("/dead_letter")
        dl = dl_body["dead_letter"]
        self.assertTrue(any(e["to_alias"] == "nobody" for e in dl))

    def test_send_missing_fields_returns_400(self):
        status, body = self.post("/send", {"from_alias": "send-alice"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error_code"], "bad_request")

    def test_send_with_message_id(self):
        status, body = self.post("/send", {
            "from_alias": "send-alice",
            "to_alias": "send-bob",
            "content": "stable id test",
            "message_id": "my-stable-id-999",
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["message_id"], "my-stable-id-999")


# ---------------------------------------------------------------------------
# /poll_inbox
# ---------------------------------------------------------------------------

class PollInboxTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-poll-a", "sess-poll-a", "poll-alice")
        cls._relay.register("node-poll-b", "sess-poll-b", "poll-bob")

    def test_poll_returns_messages(self):
        self._relay.send("poll-alice", "poll-bob", "hello poll")
        status, body = self.post("/poll_inbox", {
            "node_id": "node-poll-b", "session_id": "sess-poll-b"
        })
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        contents = [m["content"] for m in body["messages"]]
        self.assertIn("hello poll", contents)

    def test_poll_drains_inbox(self):
        self._relay.send("poll-alice", "poll-bob", "drain-me")
        self.post("/poll_inbox", {"node_id": "node-poll-b", "session_id": "sess-poll-b"})
        # Second poll returns no new messages (drain-me already consumed)
        status, body = self.post("/poll_inbox", {
            "node_id": "node-poll-b", "session_id": "sess-poll-b"
        })
        self.assertEqual(status, 200)
        self.assertEqual(body["messages"], [])

    def test_poll_missing_fields_returns_400(self):
        status, body = self.post("/poll_inbox", {"node_id": "node-poll-b"})
        self.assertEqual(status, 400)

    def test_poll_message_shape(self):
        self._relay.send("poll-alice", "poll-bob", "shape-check")
        _, body = self.post("/poll_inbox", {
            "node_id": "node-poll-b", "session_id": "sess-poll-b"
        })
        msg = next(m for m in body["messages"] if m["content"] == "shape-check")
        for key in ("message_id", "from_alias", "to_alias", "content", "ts"):
            self.assertIn(key, msg)


# ---------------------------------------------------------------------------
# /peek_inbox
# ---------------------------------------------------------------------------

class PeekInboxTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-peek-a", "sess-peek-a", "peek-alice")
        cls._relay.register("node-peek-b", "sess-peek-b", "peek-bob")

    def test_peek_returns_messages(self):
        self._relay.send("peek-alice", "peek-bob", "peek content")
        status, body = self.post("/peek_inbox", {
            "node_id": "node-peek-b", "session_id": "sess-peek-b"
        })
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertTrue(any(m["content"] == "peek content" for m in body["messages"]))

    def test_peek_does_not_drain(self):
        self._relay.send("peek-alice", "peek-bob", "stay-here")
        # Peek twice
        self.post("/peek_inbox", {"node_id": "node-peek-b", "session_id": "sess-peek-b"})
        _, body2 = self.post("/peek_inbox", {
            "node_id": "node-peek-b", "session_id": "sess-peek-b"
        })
        self.assertTrue(any(m["content"] == "stay-here" for m in body2["messages"]))

    def test_peek_missing_fields_returns_400(self):
        status, body = self.post("/peek_inbox", {"node_id": "node-peek-b"})
        self.assertEqual(status, 400)


# ---------------------------------------------------------------------------
# /dead_letter
# ---------------------------------------------------------------------------

class DeadLetterTests(_RelayServerTestBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._relay.register("node-dl", "sess-dl", "dl-sender")
        try:
            cls._relay.send("dl-sender", "ghost-recipient", "lost message")
        except Exception:
            pass

    def test_dead_letter_returns_list(self):
        status, body = self.get("/dead_letter")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertIn("dead_letter", body)
        self.assertIsInstance(body["dead_letter"], list)

    def test_dead_letter_contains_lost_message(self):
        _, body = self.get("/dead_letter")
        entries = body["dead_letter"]
        self.assertTrue(any(e["to_alias"] == "ghost-recipient" for e in entries))

    def test_dead_letter_not_consuming(self):
        """Two GET /dead_letter calls return the same entries."""
        _, body1 = self.get("/dead_letter")
        _, body2 = self.get("/dead_letter")
        count1 = len(body1["dead_letter"])
        count2 = len(body2["dead_letter"])
        self.assertEqual(count1, count2)


# ---------------------------------------------------------------------------
# Unknown path
# ---------------------------------------------------------------------------

class UnknownPathTests(_RelayServerTestBase):
    def test_unknown_get_path_returns_404(self):
        status, body = self.get("/nonexistent")
        self.assertEqual(status, 404)
        self.assertEqual(body["error_code"], "not_found")

    def test_unknown_post_path_returns_404(self):
        status, body = self.post("/nonexistent", {})
        self.assertEqual(status, 404)
        self.assertEqual(body["error_code"], "not_found")

    def test_bad_json_body_returns_400(self):
        req = urllib.request.Request(self.url("/register"), data=b"not json", method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {self.TOKEN}")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                status, body = resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            try:
                status, body = e.code, json.loads(e.read())
            finally:
                e.close()
        self.assertEqual(status, 400)
        self.assertEqual(body["error_code"], "bad_request")


# ---------------------------------------------------------------------------
# Concurrent requests
# ---------------------------------------------------------------------------

class ConcurrentTests(_RelayServerTestBase):
    def test_concurrent_sends_all_delivered(self):
        relay = InMemoryRelay()
        server, thread = start_server_thread("127.0.0.1", 0, token=None, relay=relay)
        try:
            _, port = server.server_address
            base = f"http://127.0.0.1:{port}"
            relay.register("node-a", "sess-sender", "csender")
            relay.register("node-b", "sess-recv", "crecv")

            n = 20
            errors = []

            def send_batch(start):
                for i in range(start, start + n):
                    s, b = _post(base + "/send", {
                        "from_alias": "csender",
                        "to_alias": "crecv",
                        "content": f"msg-{i}",
                    })
                    if s != 200:
                        errors.append((s, b))

            threads = [threading.Thread(target=send_batch, args=(i * n,)) for i in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

            self.assertEqual(errors, [], f"Send errors: {errors}")

            s, b = _post(base + "/poll_inbox", {
                "node_id": "node-b", "session_id": "sess-recv"
            })
            self.assertEqual(s, 200)
            self.assertEqual(len(b["messages"]), 4 * n)
        finally:
            server.shutdown()
            thread.join(timeout=2)


# ---------------------------------------------------------------------------
# Full end-to-end scenario: two nodes communicate via relay server
# ---------------------------------------------------------------------------

class TwoNodeEndToEndTests(_RelayServerTestBase):
    """Simulate node-laptop and node-server using the HTTP relay API."""

    def test_full_roundtrip(self):
        relay = InMemoryRelay()
        server, thread = start_server_thread("127.0.0.1", 0, token="e2e-token", relay=relay)
        try:
            _, port = server.server_address
            base = f"http://127.0.0.1:{port}"
            token = "e2e-token"

            # Register both nodes
            s, b = _post(base + "/register", {
                "node_id": "laptop", "session_id": "sess-laptop",
                "alias": "agent-a", "client_type": "claude-code",
            }, token=token)
            self.assertEqual(s, 200)

            s, b = _post(base + "/register", {
                "node_id": "server", "session_id": "sess-server",
                "alias": "agent-b", "client_type": "codex",
            }, token=token)
            self.assertEqual(s, 200)

            # A sends to B
            s, b = _post(base + "/send", {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "ping from laptop",
            }, token=token)
            self.assertEqual(s, 200)
            msg_id = b["message_id"]

            # B polls and gets the message
            s, b = _post(base + "/poll_inbox", {
                "node_id": "server", "session_id": "sess-server"
            }, token=token)
            self.assertEqual(s, 200)
            self.assertEqual(len(b["messages"]), 1)
            msg = b["messages"][0]
            self.assertEqual(msg["content"], "ping from laptop")
            self.assertEqual(msg["message_id"], msg_id)

            # B replies to A
            s, b = _post(base + "/send", {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "pong from server",
            }, token=token)
            self.assertEqual(s, 200)

            # A polls and gets the reply
            s, b = _post(base + "/poll_inbox", {
                "node_id": "laptop", "session_id": "sess-laptop"
            }, token=token)
            self.assertEqual(s, 200)
            self.assertEqual(b["messages"][0]["content"], "pong from server")

        finally:
            server.shutdown()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
