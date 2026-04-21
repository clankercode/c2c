#!/usr/bin/env python3
"""Tests for c2c_relay_connector — Phase 3: two-broker localhost proof.

Proves machine-A → machine-B message delivery with:
  - Two broker roots (simulating two machines)
  - One shared relay server
  - Two connectors, each bridging one broker root

The whole test runs in-process: relay server in a daemon thread, connectors
called synchronously via sync().
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

from c2c_relay_connector import (  # noqa: E402
    RelayClient,
    RelayConnector,
    append_to_local_inbox,
    load_local_registrations,
    load_outbox,
    local_inbox_path,
    save_outbox,
)
from c2c_relay_server import start_server_thread  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def write_registry(broker_root: Path, registrations: list[dict]) -> None:
    """Write a minimal registry.json for the connector to read."""
    (broker_root / "registry.json").write_text(
        json.dumps(registrations), encoding="utf-8"
    )


def read_inbox(broker_root: Path, session_id: str) -> list[dict]:
    """Read local inbox JSON array (returns [] if missing)."""
    path = local_inbox_path(broker_root, session_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except Exception:
        return []


def queue_outbound(broker_root: Path, from_alias: str, to_alias: str,
                   content: str) -> None:
    """Append one record to remote-outbox.jsonl."""
    outbox = broker_root / "remote-outbox.jsonl"
    import uuid
    entry = {
        "from_alias": from_alias,
        "to_alias": to_alias,
        "content": content,
        "message_id": str(uuid.uuid4()),
    }
    with outbox.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


# ---------------------------------------------------------------------------
# Base test case with shared relay server
# ---------------------------------------------------------------------------

class TwoBrokerTestCase(unittest.TestCase):
    """Sets up: relay server + two temp broker roots + two connectors."""

    @classmethod
    def setUpClass(cls):
        cls.server, cls.thread = start_server_thread("127.0.0.1", 0, token="test")
        port = cls.server.server_address[1]
        cls.relay_url = f"http://127.0.0.1:{port}"
        cls.token = "test"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=2)

    def setUp(self):
        self._dirs = []

    def tearDown(self):
        for d in self._dirs:
            d.cleanup()
        self._dirs = []

    def _broker_root(self) -> Path:
        d = tempfile.TemporaryDirectory()
        self._dirs.append(d)
        p = Path(d.name)
        p.mkdir(parents=True, exist_ok=True)
        return p

    def _connector(self, broker_root: Path, node_id: str,
                   ttl: float = 300.0) -> RelayConnector:
        client = RelayClient(self.relay_url, token=self.token)
        return RelayConnector(client, broker_root, node_id, heartbeat_ttl=ttl)


# ---------------------------------------------------------------------------
# Local broker helpers
# ---------------------------------------------------------------------------

class LocalBrokerHelpersTests(unittest.TestCase):
    def test_load_local_registrations_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(load_local_registrations(Path(d)), [])

    def test_load_local_registrations_basic(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            write_registry(root, [
                {"session_id": "s1", "alias": "alice"},
                {"session_id": "s2", "alias": "bob"},
            ])
            regs = load_local_registrations(root)
            self.assertEqual(len(regs), 2)
            aliases = {r["alias"] for r in regs}
            self.assertEqual(aliases, {"alice", "bob"})

    def test_append_to_local_inbox_creates_file(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            msgs = [{"content": "hello", "from_alias": "a", "to_alias": "b", "ts": 1}]
            append_to_local_inbox(root, "sess-1", msgs)
            delivered = read_inbox(root, "sess-1")
            self.assertEqual(len(delivered), 1)
            self.assertEqual(delivered[0]["content"], "hello")

    def test_append_to_local_inbox_accumulates(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            append_to_local_inbox(root, "s", [{"content": "1"}])
            append_to_local_inbox(root, "s", [{"content": "2"}])
            msgs = read_inbox(root, "s")
            self.assertEqual(len(msgs), 2)

    def test_outbox_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            queue_outbound(root, "alice", "bob", "hi")
            entries = load_outbox(root)
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0]["from_alias"], "alice")

    def test_save_outbox_empty_removes_file(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            queue_outbound(root, "a", "b", "x")
            save_outbox(root, [])
            self.assertFalse((root / "remote-outbox.jsonl").exists())


# ---------------------------------------------------------------------------
# Connector sync tests
# ---------------------------------------------------------------------------

class ConnectorSyncTests(TwoBrokerTestCase):
    def test_sync_registers_local_aliases(self):
        root = self._broker_root()
        write_registry(root, [{"session_id": "sess-x", "alias": "node-x-agent"}])
        conn = self._connector(root, "machine-x")
        result = conn.sync()
        self.assertIn("node-x-agent", result["registered"])

    def test_sync_heartbeats_on_second_call(self):
        root = self._broker_root()
        write_registry(root, [{"session_id": "sess-hb", "alias": "hb-agent"}])
        conn = self._connector(root, "machine-hb")
        conn.sync()  # register
        result = conn.sync()  # heartbeat
        self.assertIn("hb-agent", result["heartbeated"])

    def test_sync_forwards_outbox(self):
        root_a = self._broker_root()
        root_b = self._broker_root()

        # Register both sides
        write_registry(root_a, [{"session_id": "sess-a", "alias": "agent-a"}])
        write_registry(root_b, [{"session_id": "sess-b", "alias": "agent-b"}])
        conn_a = self._connector(root_a, "machine-a")
        conn_b = self._connector(root_b, "machine-b")
        conn_a.sync()
        conn_b.sync()

        # Queue outbound from A to B
        queue_outbound(root_a, "agent-a", "agent-b", "hello from A")

        result = conn_a.sync()
        self.assertEqual(result["outbox_forwarded"], 1)
        self.assertEqual(result["outbox_failed"], 0)

    def test_sync_delivers_inbound_to_local_inbox(self):
        root_a = self._broker_root()
        root_b = self._broker_root()

        write_registry(root_a, [{"session_id": "sess-a2", "alias": "agent-a2"}])
        write_registry(root_b, [{"session_id": "sess-b2", "alias": "agent-b2"}])
        conn_a = self._connector(root_a, "machine-a2")
        conn_b = self._connector(root_b, "machine-b2")
        conn_a.sync()
        conn_b.sync()

        queue_outbound(root_a, "agent-a2", "agent-b2", "cross-machine msg")
        conn_a.sync()  # forward outbox

        result = conn_b.sync()  # pull inbound
        self.assertGreater(result["inbound_delivered"], 0)

        inbox = read_inbox(root_b, "sess-b2")
        contents = [m["content"] for m in inbox]
        self.assertIn("cross-machine msg", contents)

    def test_sync_failed_send_stays_in_outbox(self):
        root = self._broker_root()
        write_registry(root, [{"session_id": "sess-x", "alias": "agent-x"}])
        conn = self._connector(root, "machine-x2")
        conn.sync()

        # Queue send to unknown alias → will fail at relay
        queue_outbound(root, "agent-x", "does-not-exist", "lost message")
        result = conn.sync()
        self.assertEqual(result["outbox_failed"], 1)
        # Failed entry stays in outbox
        remaining = load_outbox(root)
        self.assertEqual(len(remaining), 1)


# ---------------------------------------------------------------------------
# Full two-machine roundtrip
# ---------------------------------------------------------------------------

class TwoMachineRoundtripTests(TwoBrokerTestCase):
    """Proves machine-A → machine-B delivery and reply on localhost."""

    def test_full_roundtrip(self):
        root_a = self._broker_root()
        root_b = self._broker_root()

        write_registry(root_a, [{"session_id": "sess-rt-a", "alias": "rt-alice"}])
        write_registry(root_b, [{"session_id": "sess-rt-b", "alias": "rt-bob"}])

        conn_a = self._connector(root_a, "machine-rt-a")
        conn_b = self._connector(root_b, "machine-rt-b")

        # Both register with relay
        conn_a.sync()
        conn_b.sync()

        # Alice (on machine-A) sends to Bob (on machine-B)
        queue_outbound(root_a, "rt-alice", "rt-bob", "ping from Alice")
        conn_a.sync()  # forward

        # Bob polls relay (machine-B connector syncs)
        conn_b.sync()
        bob_inbox = read_inbox(root_b, "sess-rt-b")
        bob_contents = [m["content"] for m in bob_inbox]
        self.assertIn("ping from Alice", bob_contents)

        # Bob replies
        queue_outbound(root_b, "rt-bob", "rt-alice", "pong from Bob")
        conn_b.sync()  # forward

        # Alice receives reply
        conn_a.sync()
        alice_inbox = read_inbox(root_a, "sess-rt-a")
        alice_contents = [m["content"] for m in alice_inbox]
        self.assertIn("pong from Bob", alice_contents)

    def test_multiple_sessions_per_node(self):
        """Multiple agents on one machine all get their messages."""
        root = self._broker_root()
        write_registry(root, [
            {"session_id": "sess-m1", "alias": "multi-1"},
            {"session_id": "sess-m2", "alias": "multi-2"},
        ])
        root_sender = self._broker_root()
        write_registry(root_sender, [{"session_id": "sess-s", "alias": "sender-m"}])

        conn = self._connector(root, "machine-multi")
        conn_s = self._connector(root_sender, "machine-sender")
        conn.sync()
        conn_s.sync()

        queue_outbound(root_sender, "sender-m", "multi-1", "to m1")
        queue_outbound(root_sender, "sender-m", "multi-2", "to m2")
        conn_s.sync()

        conn.sync()
        inbox1 = read_inbox(root, "sess-m1")
        inbox2 = read_inbox(root, "sess-m2")
        self.assertIn("to m1", [m["content"] for m in inbox1])
        self.assertIn("to m2", [m["content"] for m in inbox2])


# ---------------------------------------------------------------------------
# RelayClient tests
# ---------------------------------------------------------------------------

class RelayClientTests(TwoBrokerTestCase):
    def test_health(self):
        client = RelayClient(self.relay_url, token=self.token)
        r = client.health()
        self.assertTrue(r["ok"])

    def test_health_no_auth_required(self):
        client = RelayClient(self.relay_url)  # no token
        r = client.health()
        self.assertTrue(r["ok"])

    def test_connection_error_returns_error_dict(self):
        client = RelayClient("http://127.0.0.1:1", timeout=1.0)
        r = client.health()
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "connection_error")


# ---------------------------------------------------------------------------
# Ed25519 signing unit tests
# ---------------------------------------------------------------------------

class Ed25519SigningTests(unittest.TestCase):
    """Unit tests for the _sign_peer_request function and identity loading."""

    def _make_temp_identity(self, tmp_dir: Path) -> tuple[Path, dict]:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from c2c_relay_connector import _b64url_nopad
        priv = Ed25519PrivateKey.generate()
        pub = priv.public_key()
        sk_bytes = priv.private_bytes_raw()
        pk_bytes = pub.public_bytes_raw()
        identity = {
            "version": 1,
            "alg": "ed25519",
            "public_key": _b64url_nopad(pk_bytes),
            "private_key": _b64url_nopad(sk_bytes),
            "fingerprint": "SHA256:test",
            "created_at": "2026-01-01T00:00:00Z",
            "alias_hint": "test-agent",
        }
        p = tmp_dir / "identity.json"
        p.write_text(json.dumps(identity), encoding="utf-8")
        p.chmod(0o600)
        return p, identity

    def test_sign_peer_request_header_format(self):
        from c2c_relay_connector import _sign_peer_request
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            header = _sign_peer_request(identity, "test-alias", "POST", "/heartbeat",
                                        b'{"node_id":"n1","session_id":"s1"}')
        self.assertTrue(header.startswith("Ed25519 "))
        parts = dict(kv.split("=", 1) for kv in header[len("Ed25519 "):].split(","))
        self.assertEqual(parts["alias"], "test-alias")
        self.assertIn("ts", parts)
        self.assertIn("nonce", parts)
        self.assertIn("sig", parts)

    def test_sign_peer_request_signature_is_valid(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        from c2c_relay_connector import _sign_peer_request, _b64url_nopad, _UNIT_SEP, _REQUEST_SIGN_CTX
        import base64
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            body = b'{"node_id":"n1","session_id":"s1"}'
            header = _sign_peer_request(identity, "test-alias", "POST", "/heartbeat", body)
        parts = dict(kv.split("=", 1) for kv in header[len("Ed25519 "):].split(","))
        ts = parts["ts"]
        nonce = parts["nonce"]
        sig_b64 = parts["sig"] + "=="
        sig = base64.urlsafe_b64decode(sig_b64)
        # reconstruct canonical blob
        import hashlib
        body_hash = _b64url_nopad(hashlib.sha256(body).digest())
        blob = _UNIT_SEP.join([_REQUEST_SIGN_CTX, "POST", "/heartbeat", "", body_hash, ts, nonce])
        # verify
        pk_bytes = base64.urlsafe_b64decode(identity["public_key"] + "==")
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        pub = Ed25519PublicKey.from_public_bytes(pk_bytes)
        pub.verify(sig, blob.encode())  # raises if invalid

    def test_load_identity_from_path(self):
        from c2c_relay_connector import _load_identity
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            loaded = _load_identity(str(p))
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded["alg"], "ed25519")

    def test_load_identity_rejects_permissive_file(self):
        from c2c_relay_connector import _load_identity
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            p.chmod(0o644)  # too permissive
            loaded = _load_identity(str(p))
        self.assertIsNone(loaded)

    def test_relay_client_uses_bearer_without_identity(self):
        """When no identity_path is set, RelayClient uses Bearer token."""
        # RelayClient without identity_path won't load identity
        client = RelayClient("http://127.0.0.1:9999", token="mytoken")
        self.assertIsNone(client._identity)

    def test_relay_client_loads_identity_from_path(self):
        """When identity_path is set, RelayClient loads identity for signing."""
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="mytoken",
                                 identity_path=str(p))
        self.assertIsNotNone(client._identity)
        self.assertEqual(client._identity["alg"], "ed25519")

    def test_sign_register_body_has_required_fields(self):
        from c2c_relay_connector import _sign_register_body
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            extra = _sign_register_body(identity, "my-agent", "https://relay.example.com")
        for field in ("identity_pk", "signature", "nonce", "timestamp"):
            self.assertIn(field, extra)
        self.assertEqual(extra["identity_pk"], identity["public_key"])

    def test_sign_register_body_signature_verifies(self):
        from c2c_relay_connector import _sign_register_body, _b64url_nopad, _UNIT_SEP, _REGISTER_SIGN_CTX
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        import base64, tempfile
        alias = "my-agent"
        relay_url = "https://relay.example.com"
        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            extra = _sign_register_body(identity, alias, relay_url)
        pk_bytes = base64.urlsafe_b64decode(identity["public_key"] + "==")
        pub = Ed25519PublicKey.from_public_bytes(pk_bytes)
        sig = base64.urlsafe_b64decode(extra["signature"] + "==")
        blob = _UNIT_SEP.join([_REGISTER_SIGN_CTX, alias, relay_url.lower().rstrip("/"),
                               extra["identity_pk"], extra["timestamp"], extra["nonce"]])
        pub.verify(sig, blob.encode())  # raises if invalid

    def test_register_includes_signed_fields_when_identity_present(self):
        """register() body includes identity_pk + signature when identity is loaded."""
        import io, tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, identity = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["body"] = json.loads(req.data.decode())
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.register("n1", "s1", "my-alias")

        body = captured.get("body", {})
        self.assertIn("identity_pk", body)
        self.assertIn("signature", body)
        self.assertIn("nonce", body)
        self.assertIn("timestamp", body)
        self.assertEqual(body["identity_pk"], identity["public_key"])

    def test_heartbeat_uses_ed25519_auth_when_identity_present(self):
        """heartbeat() Authorization header is Ed25519 when identity is loaded."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.heartbeat("n1", "s1", alias="my-alias")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")

    def test_send_uses_ed25519_auth_when_identity_present(self):
        """send() Authorization header is Ed25519 when identity is loaded."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.send("sender", "target", "hello world")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")

    def test_poll_inbox_uses_ed25519_auth_when_identity_present(self):
        """poll_inbox() Authorization header is Ed25519 when identity is loaded."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true, "messages": []}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.poll_inbox("n1", "s1", alias="my-alias")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")

    def test_heartbeat_uses_bearer_when_no_identity(self):
        """heartbeat() uses Bearer when no identity is loaded."""
        from unittest.mock import patch, MagicMock

        client = RelayClient("http://127.0.0.1:9999", token="my-bearer-tok")

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.heartbeat("n1", "s1", alias="my-alias")

        auth = captured.get("auth", "")
        self.assertEqual(auth, "Bearer my-bearer-tok")

    def test_join_room_uses_ed25519_auth_when_identity_present(self):
        """join_room() Authorization header is Ed25519 when identity is loaded (fix: 970940f)."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.join_room("my-alias", "swarm-lounge")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")

    def test_leave_room_uses_ed25519_auth_when_identity_present(self):
        """leave_room() Authorization header is Ed25519 when identity is loaded (fix: 970940f)."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.leave_room("my-alias", "swarm-lounge")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")

    def test_send_room_uses_ed25519_auth_when_identity_present(self):
        """send_room() Authorization header is Ed25519 when identity is loaded (fix: 970940f)."""
        import tempfile
        from unittest.mock import patch, MagicMock

        with tempfile.TemporaryDirectory() as d:
            p, _ = self._make_temp_identity(Path(d))
            client = RelayClient("http://127.0.0.1:9999", token="tok",
                                 identity_path=str(p))

        captured = {}
        def fake_urlopen(req, timeout=None, context=None):
            captured["auth"] = req.get_header("Authorization")
            resp = MagicMock()
            resp.read.return_value = b'{"ok": true}'
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        with patch("urllib.request.urlopen", fake_urlopen):
            client.send_room("my-alias", "swarm-lounge", "hello world")

        auth = captured.get("auth", "")
        self.assertTrue(auth.startswith("Ed25519 "), f"Expected Ed25519 header, got: {auth}")


if __name__ == "__main__":
    unittest.main()
