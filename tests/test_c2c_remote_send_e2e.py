#!/usr/bin/env python3
"""Integration test: c2c send <alias@host> remote-outbox roundtrip.

Exercises the full path:
  c2c send alice@relay --from alice
    → enqueue_message detects '@', appends to remote-outbox.jsonl
    → c2c relay connect --once reads outbox, POSTs to relay
    → c2c relay connect --once (receiver side) polls inbox from relay
    → message lands in receiver's local inbox

Uses two temp broker roots (alice-side, bob-side) + InMemoryRelay
in-process server. Gated behind C2C_TEST_REMOTE_SEND=1.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

import pytest

C2C_BIN = shutil.which("c2c")

pytestmark = [
    pytest.mark.skipif(C2C_BIN is None, reason="c2c binary not on PATH"),
    pytest.mark.skipif(
        os.environ.get("C2C_TEST_REMOTE_SEND") != "1",
        reason="set C2C_TEST_REMOTE_SEND=1 to enable",
    ),
]

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_contract import InMemoryRelay
from c2c_relay_server import start_server_thread


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# In-memory relay server (shared across tests in this module)
# ---------------------------------------------------------------------------

_shared_relay: InMemoryRelay | None = None
_shared_server: threading.Thread | None = None
_shared_port: int = 0
_SHARED_TOKEN = "remote-send-test-token"


def setup_module() -> None:
    global _shared_relay, _shared_server, _shared_port
    _shared_relay = InMemoryRelayWithHostStrip()
    _shared_server, _ = start_server_thread(
        "127.0.0.1", 0, token=_SHARED_TOKEN, relay=_shared_relay
    )
    _shared_port = _shared_server.server_address[1]


def teardown_module() -> None:
    if _shared_server:
        _shared_server.shutdown()


# ---------------------------------------------------------------------------
# In-memory relay with @host suffix stripping (mirrors real relay behavior)
# ---------------------------------------------------------------------------

class InMemoryRelayWithHostStrip(InMemoryRelay):
    """InMemoryRelay that strips @host suffix from to_alias in send().

    Real relay servers route based on the host portion of alias@host.
    This subclass mirrors that behavior for integration testing.
    """

    def send(self, from_alias: str, to_alias: str, content: str,
             *, message_id: str | None = None) -> dict:
        # Strip @host suffix to get the actual delivery target
        at_pos = to_alias.find("@")
        target_alias = to_alias[:at_pos] if at_pos > 0 else to_alias
        return super().send(from_alias, target_alias, content, message_id=message_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_c2c(
    *args: str,
    home: Path,
    relay_url: str,
    env_extra: dict[str, str] | None = None,
    timeout: int = 30,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess:
    """Run c2c CLI with isolated HOME and broker root.

    NOTE: env dict replaces the entire process environment, so every
    variable the OCaml binary needs must be passed explicitly.
    C2C_RELAY_CONNECTOR_BACKEND=python is REQUIRED to route
    relay connect to the Python connector (which uses InMemoryRelay).
    """
    env: dict[str, str] = {
        "HOME": str(home),
        "C2C_MCP_BROKER_ROOT": str(home / "broker"),
        "C2C_RELAY_CONNECTOR_BACKEND": "python",
        "C2C_RELAY_TOKEN": _SHARED_TOKEN,
        # Preserve critical read-only env vars the OCaml binary needs
        "USER": os.environ.get("USER", "test"),
        "PATH": os.environ["PATH"],
    }
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [C2C_BIN, *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(cwd if cwd is not None else home),
    )


def _make_broker(root: Path, alias: str) -> None:
    """Create minimal broker dir with registry.json matching Python connector format."""
    # Python connector reads a plain list of {session_id, alias, client_type}
    registry = [{"alias": alias, "session_id": f"sess-{alias}", "client_type": "codex"}]
    (root / "registry.json").write_text(json.dumps(registry), encoding="utf-8")


class TestRemoteSendAliasHostE2E(unittest.TestCase):
    """E2E tests for alias@host remote send path."""

    def setUp(self) -> None:
        self.relay_url = f"http://127.0.0.1:{_shared_port}"
        self.alice_root = Path(tempfile.mkdtemp())
        self.alice_broker = self.alice_root / "broker"
        self.alice_broker.mkdir()
        self.bob_root = Path(tempfile.mkdtemp())
        self.bob_broker = self.bob_root / "broker"
        self.bob_broker.mkdir()
        self.addCleanup(self._cleanup)

    def _cleanup(self) -> None:
        shutil.rmtree(self.alice_root, ignore_errors=True)
        shutil.rmtree(self.bob_root, ignore_errors=True)

    def test_send_alias_at_host_writes_remote_outbox(self) -> None:
        """c2c send <alias@host> writes entry to remote-outbox.jsonl."""
        _make_broker(self.alice_broker, "alice")
        r = _run_c2c(
            "send", "bob@relay", "hello remote bob",
            home=self.alice_root,
            relay_url=self.relay_url,
            env_extra={
                "C2C_MCP_SESSION_ID": "sess-alice",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "alice",
            },
        )
        self.assertEqual(r.returncode, 0, f"send failed: {r.stderr}")
        outbox_path = self.alice_broker / "remote-outbox.jsonl"
        self.assertTrue(outbox_path.exists(), "remote-outbox.jsonl not created")
        lines = outbox_path.read_text().strip().split("\n")
        self.assertEqual(len(lines), 1)
        entry = json.loads(lines[0])
        self.assertEqual(entry["to_alias"], "bob@relay")
        self.assertEqual(entry["content"], "hello remote bob")

    def test_alias_at_host_roundtrip_via_relay(self) -> None:
        """Full roundtrip: alice@relay → relay → bob via c2c relay connect."""
        _make_broker(self.alice_broker, "alice")
        _make_broker(self.bob_broker, "bob")

        # Both sides: relay setup
        for root, alias in [(self.alice_root, "alice"), (self.bob_root, "bob")]:
            r = _run_c2c(
                "relay", "setup", "--url", self.relay_url,
                home=root, relay_url=self.relay_url,
            )
            self.assertEqual(r.returncode, 0, f"relay setup failed: {r.stderr}")

        # alice: relay connect --once first (registers alice with relay)
        r = _run_c2c(
            "relay", "connect", "--once",
            "--relay-url", self.relay_url,
            "--interval", "1",
            home=self.alice_root,
            relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        self.assertEqual(r.returncode, 0, f"alice relay connect (register) failed: {r.stderr}")

        # bob: relay connect --once (registers bob)
        r = _run_c2c(
            "relay", "connect", "--once",
            "--relay-url", self.relay_url,
            "--interval", "1",
            home=self.bob_root,
            relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        self.assertEqual(r.returncode, 0, f"bob relay connect (register) failed: {r.stderr}")

        # alice: send to bob@relay (remote alias)
        r = _run_c2c(
            "send", "bob@relay", "ping via relay",
            home=self.alice_root,
            relay_url=self.relay_url,
            env_extra={
                "C2C_MCP_SESSION_ID": "sess-alice",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "alice",
            },
        )
        self.assertEqual(r.returncode, 0, f"alice send failed: {r.stderr}")

        # alice: relay connect --once (forwards outbox to relay)
        r = _run_c2c(
            "relay", "connect", "--once",
            "--relay-url", self.relay_url,
            "--interval", "1",
            home=self.alice_root,
            relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        self.assertEqual(r.returncode, 0, f"alice relay connect (forward) failed: {r.stderr}")

        # bob: relay connect --once (polls inbox from relay)
        r = _run_c2c(
            "relay", "connect", "--once",
            "--relay-url", self.relay_url,
            "--interval", "1",
            home=self.bob_root,
            relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        self.assertEqual(r.returncode, 0, f"bob relay connect (poll) failed: {r.stderr}")

        # bob's local inbox should have the message
        inbox_path = self.bob_broker / "sess-bob.inbox.json"
        self.assertTrue(inbox_path.exists(), f"bob inbox not created: {r.stderr}")
        inbox = json.loads(inbox_path.read_text())
        self.assertTrue(
            any(m.get("content") == "ping via relay" for m in inbox),
            f"message not in bob's inbox: {inbox}",
        )

    def test_reply_alias_at_host_roundtrip(self) -> None:
        """Bidirectional: alice@relay → bob → alice@relay."""
        _make_broker(self.alice_broker, "alice")
        _make_broker(self.bob_broker, "bob")

        for root, alias in [(self.alice_root, "alice"), (self.bob_root, "bob")]:
            r = _run_c2c(
                "relay", "setup", "--url", self.relay_url,
                home=root, relay_url=self.relay_url,
            )
            self.assertEqual(r.returncode, 0, f"relay setup failed: {r.stderr}")

        # Both sides: relay connect --once to register
        for root in [self.alice_root, self.bob_root]:
            r = _run_c2c(
                "relay", "connect", "--once", "--relay-url", self.relay_url,
                home=root, relay_url=self.relay_url,
                env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
                cwd=REPO,
            )
            self.assertEqual(r.returncode, 0, f"relay connect (register) failed: {r.stderr}")

        # A → B
        r = _run_c2c(
            "send", "bob@relay", "msg A→B",
            home=self.alice_root,
            relay_url=self.relay_url,
            env_extra={
                "C2C_MCP_SESSION_ID": "sess-alice",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "alice",
            },
        )
        self.assertEqual(r.returncode, 0, f"A→B send failed: {r.stderr}")
        _run_c2c(
            "relay", "connect", "--once", "--relay-url", self.relay_url,
            home=self.alice_root, relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        _run_c2c(
            "relay", "connect", "--once", "--relay-url", self.relay_url,
            home=self.bob_root, relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )

        # B → A reply
        r = _run_c2c(
            "send", "alice@relay", "msg B→A reply",
            home=self.bob_root,
            relay_url=self.relay_url,
            env_extra={
                "C2C_MCP_SESSION_ID": "sess-bob",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "bob",
            },
        )
        self.assertEqual(r.returncode, 0, f"B→A send failed: {r.stderr}")
        _run_c2c(
            "relay", "connect", "--once", "--relay-url", self.relay_url,
            home=self.bob_root, relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )
        _run_c2c(
            "relay", "connect", "--once", "--relay-url", self.relay_url,
            home=self.alice_root, relay_url=self.relay_url,
            env_extra={"C2C_RELAY_TOKEN": _SHARED_TOKEN},
            cwd=REPO,
        )

        # Alice's inbox should have the reply
        inbox_path = self.alice_broker / "sess-alice.inbox.json"
        self.assertTrue(inbox_path.exists(), "alice inbox not created")
        inbox = json.loads(inbox_path.read_text())
        self.assertTrue(
            any(m.get("content") == "msg B→A reply" for m in inbox),
            f"B→A reply not in alice inbox: {inbox}",
        )


if __name__ == "__main__":
    setup_module()
    try:
        unittest.main()
    finally:
        teardown_module()
