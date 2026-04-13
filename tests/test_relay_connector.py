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

    def setUp(self):
        self._dirs = []

    def tearDown(self):
        for d in self._dirs:
            import shutil
            shutil.rmtree(d.name, ignore_errors=True)

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


if __name__ == "__main__":
    unittest.main()
