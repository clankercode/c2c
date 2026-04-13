#!/usr/bin/env python3
"""Tests for c2c_relay_server — HTTP relay parity with InMemoryRelay contract.

Starts a real ThreadingHTTPServer on a random port and runs the same
scenarios as test_relay_contract.py to verify HTTP → InMemoryRelay parity.
"""
from __future__ import annotations

import sys
import time
import unittest
import urllib.request
import urllib.error
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import (  # noqa: E402
    RELAY_ERR_ALIAS_CONFLICT,
    RELAY_ERR_RECIPIENT_DEAD,
    RELAY_ERR_UNKNOWN_ALIAS,
)
from c2c_relay_server import start_server_thread  # noqa: E402


TOKEN = "test-secret-token"


# ---------------------------------------------------------------------------
# HTTP client helper
# ---------------------------------------------------------------------------

class RelayClient:
    """Minimal synchronous HTTP client for the relay server."""

    def __init__(self, base_url: str, token: str | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body or {}).encode() if body is not None else b""
        req = urllib.request.Request(url, data=data or None, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            try:
                return json.loads(exc.read())
            finally:
                exc.close()

    def get(self, path: str) -> dict:
        return self._request("GET", path)

    def post(self, path: str, body: dict) -> dict:
        return self._request("POST", path, body)

    def register(self, node_id: str, session_id: str, alias: str, **kw) -> dict:
        return self.post("/register", {"node_id": node_id, "session_id": session_id,
                                       "alias": alias, **kw})

    def heartbeat(self, node_id: str, session_id: str) -> dict:
        return self.post("/heartbeat", {"node_id": node_id, "session_id": session_id})

    def list_peers(self, *, include_dead: bool = False) -> list[dict]:
        r = self.post("/list", {"include_dead": include_dead})
        return r.get("peers", [])

    def send(self, from_alias: str, to_alias: str, content: str, **kw) -> dict:
        return self.post("/send", {"from_alias": from_alias, "to_alias": to_alias,
                                   "content": content, **kw})

    def poll_inbox(self, node_id: str, session_id: str) -> list[dict]:
        r = self.post("/poll_inbox", {"node_id": node_id, "session_id": session_id})
        return r.get("messages", [])

    def peek_inbox(self, node_id: str, session_id: str) -> list[dict]:
        r = self.post("/peek_inbox", {"node_id": node_id, "session_id": session_id})
        return r.get("messages", [])

    def dead_letter(self) -> list[dict]:
        r = self.get("/dead_letter")
        return r.get("dead_letter", [])


# ---------------------------------------------------------------------------
# Base class for server tests
# ---------------------------------------------------------------------------

class RelayServerTestCase(unittest.TestCase):
    server = None
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server, cls.thread = start_server_thread(
            "127.0.0.1", 0, token=TOKEN
        )
        port = cls.server.server_address[1]
        cls.client = RelayClient(f"http://127.0.0.1:{port}", token=TOKEN)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()


# ---------------------------------------------------------------------------
# /health — no auth
# ---------------------------------------------------------------------------

class HealthTests(RelayServerTestCase):
    def test_health_no_auth(self):
        no_auth_client = RelayClient(f"http://127.0.0.1:{self.server.server_address[1]}")
        r = no_auth_client.get("/health")
        self.assertTrue(r["ok"])

    def test_health_with_auth(self):
        r = self.client.get("/health")
        self.assertTrue(r["ok"])


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class AuthTests(RelayServerTestCase):
    def test_no_token_returns_401(self):
        no_auth = RelayClient(f"http://127.0.0.1:{self.server.server_address[1]}")
        r = no_auth.post("/register", {"node_id": "n", "session_id": "s", "alias": "a"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "unauthorized")

    def test_wrong_token_returns_401(self):
        bad_auth = RelayClient(
            f"http://127.0.0.1:{self.server.server_address[1]}", token="wrong"
        )
        r = bad_auth.post("/list", {})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "unauthorized")

    def test_unknown_endpoint_returns_404(self):
        r = self.client.get("/nonexistent")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "not_found")


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

class HTTPRegisterTests(RelayServerTestCase):
    def setUp(self):
        # Fresh relay per test class is expensive; use unique aliases instead
        self._suffix = str(id(self)) + str(time.time()).replace(".", "")

    def _alias(self, name: str) -> str:
        return f"{name}-{self._suffix}"

    def test_register_returns_ok(self):
        r = self.client.register("node-a", "sess-1", self._alias("codex"))
        self.assertTrue(r["ok"])

    def test_register_missing_fields_returns_400(self):
        r = self.client.post("/register", {"node_id": "n"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "bad_request")

    def test_register_conflict_different_node(self):
        alias = self._alias("storm")
        self.client.register("node-a", "sess-1", alias)
        r = self.client.register("node-b", "sess-2", alias)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], RELAY_ERR_ALIAS_CONFLICT)

    def test_register_same_node_different_session_replaces(self):
        alias = self._alias("kimi")
        self.client.register("node-a", "old-sess", alias)
        r = self.client.register("node-a", "new-sess", alias)
        self.assertTrue(r["ok"])
        peers = self.client.list_peers()
        matching = [p for p in peers if p["alias"] == alias]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["session_id"], "new-sess")

    def test_register_includes_node_id(self):
        alias = self._alias("opencode")
        self.client.register("node-x", "sess-x", alias, client_type="opencode")
        peers = self.client.list_peers()
        matching = [p for p in peers if p["alias"] == alias]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["node_id"], "node-x")
        self.assertEqual(matching[0]["client_type"], "opencode")


# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

class HTTPHeartbeatTests(RelayServerTestCase):
    def setUp(self):
        self._suffix = str(id(self)) + str(time.time()).replace(".", "")

    def _alias(self, name: str) -> str:
        return f"{name}-{self._suffix}"

    def test_heartbeat_returns_ok(self):
        alias = self._alias("hb")
        self.client.register("node-hb", "sess-hb", alias)
        r = self.client.heartbeat("node-hb", "sess-hb")
        self.assertTrue(r["ok"])
        self.assertIn("last_seen", r)

    def test_heartbeat_unknown_returns_error(self):
        r = self.client.post("/heartbeat", {"node_id": "nobody", "session_id": "ghost"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], RELAY_ERR_UNKNOWN_ALIAS)


# ---------------------------------------------------------------------------
# send / poll / peek
# ---------------------------------------------------------------------------

class HTTPSendPollTests(RelayServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        sfx = "sp" + str(int(time.time() * 1000))
        cls.alice_alias = f"alice-{sfx}"
        cls.bob_alias = f"bob-{sfx}"
        cls.client.register("node-a", f"sess-a-{sfx}", cls.alice_alias)
        cls.client.register("node-b", f"sess-b-{sfx}", cls.bob_alias)
        cls._node_a = "node-a"
        cls._sess_a = f"sess-a-{sfx}"
        cls._node_b = "node-b"
        cls._sess_b = f"sess-b-{sfx}"

    def test_send_returns_ok(self):
        r = self.client.send(self.alice_alias, self.bob_alias, "hello")
        self.assertTrue(r["ok"])
        self.assertIn("ts", r)
        self.assertIn("message_id", r)

    def test_poll_drains_inbox(self):
        self.client.send(self.alice_alias, self.bob_alias, "__poll1__")
        msgs = self.client.poll_inbox(self._node_b, self._sess_b)
        contents = [m["content"] for m in msgs]
        self.assertIn("__poll1__", contents)

    def test_poll_empties_after_drain(self):
        # Ensure inbox is empty from previous test pollution
        self.client.poll_inbox(self._node_b, self._sess_b)
        self.client.send(self.alice_alias, self.bob_alias, "__drain__")
        self.client.poll_inbox(self._node_b, self._sess_b)
        msgs = self.client.poll_inbox(self._node_b, self._sess_b)
        self.assertEqual(msgs, [])

    def test_peek_is_non_destructive(self):
        self.client.poll_inbox(self._node_b, self._sess_b)  # drain first
        self.client.send(self.alice_alias, self.bob_alias, "__peek__")
        peek1 = self.client.peek_inbox(self._node_b, self._sess_b)
        peek2 = self.client.peek_inbox(self._node_b, self._sess_b)
        self.assertGreater(len(peek1), 0)
        self.assertEqual(len(peek1), len(peek2))
        poll = self.client.poll_inbox(self._node_b, self._sess_b)
        self.assertGreater(len(poll), 0)

    def test_message_has_expected_fields(self):
        self.client.poll_inbox(self._node_b, self._sess_b)  # drain
        self.client.send(self.alice_alias, self.bob_alias, "shape-check")
        msgs = self.client.poll_inbox(self._node_b, self._sess_b)
        shape_msgs = [m for m in msgs if m["content"] == "shape-check"]
        self.assertEqual(len(shape_msgs), 1)
        msg = shape_msgs[0]
        for key in ("from_alias", "to_alias", "content", "ts", "message_id"):
            self.assertIn(key, msg)
        self.assertEqual(msg["from_alias"], self.alice_alias)
        self.assertEqual(msg["to_alias"], self.bob_alias)


# ---------------------------------------------------------------------------
# Dead-letter
# ---------------------------------------------------------------------------

class HTTPDeadLetterTests(RelayServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        sfx = "dl" + str(int(time.time() * 1000))
        cls.alice_alias = f"alice-{sfx}"
        cls.client.register("node-dl", f"sess-dl-{sfx}", cls.alice_alias)

    def test_send_unknown_returns_error(self):
        r = self.client.send(self.alice_alias, "ghost-12345", "hello")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], RELAY_ERR_UNKNOWN_ALIAS)

    def test_send_unknown_appears_in_dead_letter(self):
        self.client.send(self.alice_alias, "also-ghost-12345", "hi")
        dl = self.client.dead_letter()
        entries = [e for e in dl if e.get("to_alias") == "also-ghost-12345"]
        self.assertGreater(len(entries), 0)
        self.assertEqual(entries[0]["reason"], "unknown_alias")

    def test_dead_letter_is_non_destructive(self):
        dl1 = self.client.dead_letter()
        dl2 = self.client.dead_letter()
        self.assertEqual(len(dl1), len(dl2))

    def test_dead_letter_entry_shape(self):
        self.client.send(self.alice_alias, "shape-ghost-99", "test")
        dl = self.client.dead_letter()
        entries = [e for e in dl if e.get("to_alias") == "shape-ghost-99"]
        self.assertGreater(len(entries), 0)
        entry = entries[0]
        for key in ("ts", "message_id", "from_alias", "to_alias", "content", "reason"):
            self.assertIn(key, entry)


# ---------------------------------------------------------------------------
# make_server / start_server_thread API
# ---------------------------------------------------------------------------

class ServerAPITests(unittest.TestCase):
    def test_port_zero_picks_free_port(self):
        server, thread = start_server_thread("127.0.0.1", 0, token="t")
        port = server.server_address[1]
        self.assertGreater(port, 0)
        server.shutdown()

    def test_no_token_disables_auth(self):
        server, thread = start_server_thread("127.0.0.1", 0, token=None)
        port = server.server_address[1]
        client = RelayClient(f"http://127.0.0.1:{port}")  # no token
        r = client.register("n", "s", "alias-noauth")
        self.assertTrue(r["ok"])
        server.shutdown()

    def test_server_uses_provided_relay(self):
        from c2c_relay_contract import InMemoryRelay
        relay = InMemoryRelay()
        relay.register("n", "s", "pre-seeded")
        server, thread = start_server_thread("127.0.0.1", 0, token=None, relay=relay)
        port = server.server_address[1]
        client = RelayClient(f"http://127.0.0.1:{port}")
        peers = client.list_peers()
        aliases = [p["alias"] for p in peers]
        self.assertIn("pre-seeded", aliases)
        server.shutdown()


if __name__ == "__main__":
    unittest.main()
