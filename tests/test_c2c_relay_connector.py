"""Integration tests for c2c_relay_connector — Phase 3 cross-machine broker.

Spins up a real relay server in a background thread, then exercises
RelayConnector and RelayClient against it using temp broker directories that
simulate two separate machines.

Tests cover:
  - RelayClient: health, register, heartbeat, list_peers, send, poll_inbox
  - RelayClient connection error (server not running)
  - RelayConnector.sync: registers local aliases, delivers inbound, forwards outbox
  - Two-broker proof of concept: node-A sync → relay → node-B sync gets messages
  - --once one-shot mode via connector.run(once=True)
  - load_local_registrations: reads registry.json correctly
  - append_to_local_inbox: creates / appends to inbox file atomically
  - load_outbox / save_outbox: round-trip for remote-outbox.jsonl
"""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from c2c_relay_contract import InMemoryRelay
from c2c_relay_connector import (
    RelayClient,
    RelayConnector,
    append_to_local_inbox,
    load_local_registrations,
    load_outbox,
    local_inbox_path,
    save_outbox,
)
from c2c_relay_server import start_server_thread


# ---------------------------------------------------------------------------
# Shared test relay server (started once per module)
# ---------------------------------------------------------------------------

_shared_relay: InMemoryRelay | None = None
_shared_server = None
_shared_port: int = 0
_SHARED_TOKEN = "connector-test-token"


def setUpModule():
    global _shared_relay, _shared_server, _shared_port
    _shared_relay = InMemoryRelay()
    _shared_server, _ = start_server_thread(
        "127.0.0.1", 0, token=_SHARED_TOKEN, relay=_shared_relay
    )
    _shared_port = _shared_server.server_address[1]


def tearDownModule():
    if _shared_server:
        _shared_server.shutdown()


def _client() -> RelayClient:
    return RelayClient(f"http://127.0.0.1:{_shared_port}", token=_SHARED_TOKEN)


# ---------------------------------------------------------------------------
# RelayClient tests
# ---------------------------------------------------------------------------

class RelayClientTests(unittest.TestCase):
    def setUp(self):
        self.client = _client()

    def test_health_ok(self):
        r = self.client.health()
        self.assertTrue(r.get("ok"))

    def test_register_returns_ok(self):
        r = self.client.register("node-rc", "sess-rc-1", "rc-alice",
                                 client_type="codex")
        self.assertTrue(r.get("ok"))
        self.assertEqual(r.get("alias"), "rc-alice")

    def test_heartbeat_ok(self):
        self.client.register("node-rc-hb", "sess-rc-hb", "rc-hb-peer")
        r = self.client.heartbeat("node-rc-hb", "sess-rc-hb")
        self.assertTrue(r.get("ok"))

    def test_list_peers_returns_list(self):
        self.client.register("node-rc-list", "sess-rc-list", "rc-list-peer")
        peers = self.client.list_peers()
        self.assertIsInstance(peers, list)
        aliases = {p["alias"] for p in peers}
        self.assertIn("rc-list-peer", aliases)

    def test_send_and_poll(self):
        self.client.register("node-sp-a", "sess-sp-a", "sp-sender")
        self.client.register("node-sp-b", "sess-sp-b", "sp-receiver")
        r = self.client.send("sp-sender", "sp-receiver", "hello from client test")
        self.assertTrue(r.get("ok"))
        msgs = self.client.poll_inbox("node-sp-b", "sess-sp-b")
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "hello from client test")

    def test_poll_drains_inbox(self):
        self.client.register("node-drain-a", "sess-drain-a", "drain-sender")
        self.client.register("node-drain-b", "sess-drain-b", "drain-recv")
        self.client.send("drain-sender", "drain-recv", "drain test")
        self.client.poll_inbox("node-drain-b", "sess-drain-b")
        second_poll = self.client.poll_inbox("node-drain-b", "sess-drain-b")
        self.assertEqual(second_poll, [])

    def test_connection_error_returns_error_dict(self):
        bad_client = RelayClient("http://127.0.0.1:1", token="x", timeout=1.0)
        r = bad_client.health()
        self.assertFalse(r.get("ok"))
        self.assertEqual(r.get("error_code"), "connection_error")


# ---------------------------------------------------------------------------
# Local broker helper tests
# ---------------------------------------------------------------------------

class LoadLocalRegistrationsTests(unittest.TestCase):
    def _write_registry(self, root: Path, regs: list[dict]) -> None:
        (root / "registry.json").write_text(json.dumps(regs), encoding="utf-8")

    def test_reads_valid_registrations(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self._write_registry(root, [
                {"session_id": "s1", "alias": "a1"},
                {"session_id": "s2", "alias": "a2", "client_type": "codex"},
            ])
            regs = load_local_registrations(root)
            self.assertEqual(len(regs), 2)

    def test_missing_file_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            regs = load_local_registrations(Path(d))
            self.assertEqual(regs, [])

    def test_skips_entries_without_session_or_alias(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self._write_registry(root, [
                {"session_id": "s1"},  # no alias
                {"alias": "a2"},       # no session_id
                {"session_id": "s3", "alias": "a3"},  # valid
            ])
            regs = load_local_registrations(root)
            self.assertEqual(len(regs), 1)
            self.assertEqual(regs[0]["alias"], "a3")

    def test_malformed_json_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "registry.json").write_text("not json", encoding="utf-8")
            regs = load_local_registrations(root)
            self.assertEqual(regs, [])


class AppendToLocalInboxTests(unittest.TestCase):
    def test_creates_inbox_with_messages(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            n = append_to_local_inbox(root, "sess-1", [
                {"content": "hello", "from_alias": "alice"}
            ])
            self.assertEqual(n, 1)
            inbox = json.loads(local_inbox_path(root, "sess-1").read_text())
            self.assertEqual(len(inbox), 1)

    def test_appends_to_existing_inbox(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            append_to_local_inbox(root, "sess-1", [{"content": "first"}])
            append_to_local_inbox(root, "sess-1", [{"content": "second"}])
            inbox = json.loads(local_inbox_path(root, "sess-1").read_text())
            self.assertEqual(len(inbox), 2)

    def test_empty_messages_returns_zero(self):
        with tempfile.TemporaryDirectory() as d:
            n = append_to_local_inbox(Path(d), "sess-1", [])
            self.assertEqual(n, 0)


class OutboxTests(unittest.TestCase):
    def _root(self) -> Path:
        self._tmpdir = tempfile.mkdtemp()
        return Path(self._tmpdir)

    def test_load_empty_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            records = load_outbox(Path(d))
            self.assertEqual(records, [])

    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            msgs = [
                {"from_alias": "a", "to_alias": "b", "content": "hello"},
                {"from_alias": "a", "to_alias": "c", "content": "world"},
            ]
            save_outbox(root, msgs)
            loaded = load_outbox(root)
            self.assertEqual(len(loaded), 2)
            self.assertEqual(loaded[0]["content"], "hello")
            self.assertEqual(loaded[1]["content"], "world")

    def test_save_empty_removes_file(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            save_outbox(root, [{"from_alias": "a", "to_alias": "b", "content": "x"}])
            save_outbox(root, [])
            self.assertFalse((root / "remote-outbox.jsonl").exists())

    def test_skip_malformed_lines(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "remote-outbox.jsonl").write_text(
                '{"from_alias":"a","to_alias":"b","content":"ok"}\nnot-json\n',
                encoding="utf-8",
            )
            records = load_outbox(root)
            self.assertEqual(len(records), 1)


# ---------------------------------------------------------------------------
# RelayConnector.sync tests
# ---------------------------------------------------------------------------

class RelayConnectorSyncTests(unittest.TestCase):
    """Single-node connector tests against the shared relay server."""

    def _make_broker(self, session_id: str, alias: str,
                     client_type: str = "unknown") -> Path:
        """Create a temp broker dir with a registry.json entry."""
        d = tempfile.mkdtemp()
        root = Path(d)
        (root / "registry.json").write_text(
            json.dumps([{"session_id": session_id, "alias": alias,
                         "client_type": client_type}]),
            encoding="utf-8",
        )
        return root

    def _connector(self, broker_root: Path, node_id: str) -> RelayConnector:
        return RelayConnector(
            _client(), broker_root, node_id, verbose=False
        )

    def test_sync_registers_local_aliases(self):
        root = self._make_broker("sess-sync-reg", "sync-reg-alias")
        c = self._connector(root, "node-sync-test-1")
        result = c.sync()
        self.assertIn("sync-reg-alias", result["registered"])

    def test_sync_heartbeats_on_second_call(self):
        root = self._make_broker("sess-sync-hb", "sync-hb-alias")
        c = self._connector(root, "node-sync-test-2")
        c.sync()  # registers
        result = c.sync()  # should heartbeat
        self.assertIn("sync-hb-alias", result["heartbeated"])

    def test_sync_delivers_inbound_messages(self):
        root = self._make_broker("sess-inbound", "inbound-alias")
        c = self._connector(root, "node-inbound-test")
        c.sync()  # register inbound-alias on relay

        # Another node sends a message to inbound-alias
        relay_client = _client()
        relay_client.register("node-sender", "sess-sender-for-inbound",
                               "sender-for-inbound")
        relay_client.send("sender-for-inbound", "inbound-alias", "inbound hello")

        result = c.sync()  # pull inbound messages
        self.assertEqual(result["inbound_delivered"], 1)
        inbox = json.loads(local_inbox_path(root, "sess-inbound").read_text())
        self.assertEqual(len(inbox), 1)
        self.assertEqual(inbox[0]["content"], "inbound hello")

    def test_sync_forwards_outbox_entries(self):
        root = self._make_broker("sess-outbox", "outbox-sender")
        c = self._connector(root, "node-outbox-test")
        c.sync()  # register outbox-sender

        # Another node to receive from
        relay_client = _client()
        relay_client.register("node-outbox-recv", "sess-outbox-recv", "outbox-recv")

        # Queue an outbound message
        save_outbox(root, [{
            "from_alias": "outbox-sender",
            "to_alias": "outbox-recv",
            "content": "outbox test message",
        }])

        result = c.sync()
        self.assertEqual(result["outbox_forwarded"], 1)
        self.assertEqual(result["outbox_failed"], 0)
        # Outbox should be empty after successful forward
        self.assertEqual(load_outbox(root), [])

    def test_failed_outbox_entry_stays_in_queue(self):
        root = self._make_broker("sess-outbox-fail", "outbox-fail-sender")
        c = self._connector(root, "node-outbox-fail-test")
        c.sync()  # register sender

        save_outbox(root, [{
            "from_alias": "outbox-fail-sender",
            "to_alias": "this-alias-does-not-exist",
            "content": "will fail",
        }])

        result = c.sync()
        self.assertEqual(result["outbox_failed"], 1)
        # Entry stays in outbox for retry
        remaining = load_outbox(root)
        self.assertEqual(len(remaining), 1)

    def test_run_once(self):
        root = self._make_broker("sess-run-once", "run-once-alias")
        c = self._connector(root, "node-run-once")
        # Should complete without looping
        c.run(interval=0.01, once=True)
        # Verify it registered
        peers = _client().list_peers()
        aliases = {p["alias"] for p in peers}
        self.assertIn("run-once-alias", aliases)


# ---------------------------------------------------------------------------
# Two-broker proof of concept: node-A → relay → node-B
# ---------------------------------------------------------------------------

class TwoBrokerEndToEndTests(unittest.TestCase):
    """Prove that two connectors with different broker roots exchange messages
    through the relay: the cross-machine delivery scenario on localhost."""

    def setUp(self):
        self._relay = InMemoryRelay()
        self._server, _ = start_server_thread(
            "127.0.0.1", 0, token="e2e-two-broker", relay=self._relay
        )
        port = self._server.server_address[1]
        self._port = port
        self._token = "e2e-two-broker"

    def tearDown(self):
        self._server.shutdown()

    def _client(self) -> RelayClient:
        return RelayClient(
            f"http://127.0.0.1:{self._port}", token=self._token
        )

    def _make_broker(self, session_id: str, alias: str) -> Path:
        d = tempfile.mkdtemp()
        root = Path(d)
        (root / "registry.json").write_text(
            json.dumps([{"session_id": session_id, "alias": alias}]),
            encoding="utf-8",
        )
        return root

    def test_a_sends_to_b_via_outbox(self):
        root_a = self._make_broker("sess-a-e2e", "agent-a-e2e")
        root_b = self._make_broker("sess-b-e2e", "agent-b-e2e")

        client = self._client()
        conn_a = RelayConnector(client, root_a, "node-a-e2e", verbose=False)
        conn_b = RelayConnector(client, root_b, "node-b-e2e", verbose=False)

        # Register both nodes
        conn_a.sync()
        conn_b.sync()

        # A queues a message for B via outbox
        save_outbox(root_a, [{
            "from_alias": "agent-a-e2e",
            "to_alias": "agent-b-e2e",
            "content": "hello from A to B via relay",
        }])

        # A syncs: forwards outbox
        result_a = conn_a.sync()
        self.assertEqual(result_a["outbox_forwarded"], 1)

        # B syncs: pulls inbound
        result_b = conn_b.sync()
        self.assertGreaterEqual(result_b["inbound_delivered"], 1)

        # B's local inbox should have the message
        inbox_b = json.loads(local_inbox_path(root_b, "sess-b-e2e").read_text())
        self.assertTrue(
            any(m["content"] == "hello from A to B via relay" for m in inbox_b),
            f"Expected message not found in B's inbox: {inbox_b}",
        )

    def test_b_replies_to_a(self):
        """Round-trip: A→B and B→A both complete via relay."""
        root_a = self._make_broker("sess-a-rt", "agent-a-rt")
        root_b = self._make_broker("sess-b-rt", "agent-b-rt")

        client = self._client()
        conn_a = RelayConnector(client, root_a, "node-a-rt", verbose=False)
        conn_b = RelayConnector(client, root_b, "node-b-rt", verbose=False)

        conn_a.sync()
        conn_b.sync()

        # A → B
        save_outbox(root_a, [{"from_alias": "agent-a-rt",
                               "to_alias": "agent-b-rt", "content": "ping"}])
        conn_a.sync()
        result_b = conn_b.sync()
        self.assertEqual(result_b["inbound_delivered"], 1)

        # B → A (reply)
        save_outbox(root_b, [{"from_alias": "agent-b-rt",
                               "to_alias": "agent-a-rt", "content": "pong"}])
        conn_b.sync()
        result_a = conn_a.sync()
        self.assertEqual(result_a["inbound_delivered"], 1)

        inbox_a = json.loads(local_inbox_path(root_a, "sess-a-rt").read_text())
        self.assertTrue(any(m["content"] == "pong" for m in inbox_a))

    def test_a_inbox_unaffected_by_b_messages(self):
        """Messages sent to B do not appear in A's local inbox."""
        root_a = self._make_broker("sess-a-iso", "agent-a-iso")
        root_b = self._make_broker("sess-b-iso", "agent-b-iso")

        client = self._client()
        conn_a = RelayConnector(client, root_a, "node-a-iso", verbose=False)
        conn_b = RelayConnector(client, root_b, "node-b-iso", verbose=False)

        conn_a.sync()
        conn_b.sync()

        save_outbox(root_a, [{"from_alias": "agent-a-iso",
                               "to_alias": "agent-b-iso", "content": "for B only"}])
        conn_a.sync()
        conn_b.sync()

        inbox_a_path = local_inbox_path(root_a, "sess-a-iso")
        if inbox_a_path.exists():
            inbox_a = json.loads(inbox_a_path.read_text())
            self.assertFalse(any(m.get("content") == "for B only" for m in inbox_a))


if __name__ == "__main__":
    unittest.main()
