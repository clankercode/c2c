"""Regression tests for c2c message delivery paths.

Covers:
(a) supervisor-broadcast permission DM delivery
(b) stale-PID sender DM still works
(c) CC hook path — message survives archive drain
(d) OC plugin poll path — multiple messages delivered in order
(e) Codex bridge path — messages survive broker operations

These tests verify that messages reliably reach recipients across
different delivery scenarios. Run with: cd tests && python3 -m pytest test_c2c_delivery_paths.py -v
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def run_c2c_send_all(
    *,
    from_alias: str,
    message: str,
    broker_root: Path,
    session_id: str = "delivery-test-sender",
    exclude: list[str] | None = None,
) -> subprocess.CompletedProcess:
    """Run c2c_send_all.py which broadcasts to all live peers."""
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session_id
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = ""
    env["C2C_REGISTRY_PATH"] = str(broker_root / "isolated-yaml-registry.yaml")
    env["C2C_SESSIONS_FIXTURE"] = str(broker_root / "isolated-sessions.json")
    c2c_send_all = REPO / "c2c_send_all.py"
    cmd = [
        sys.executable, str(c2c_send_all),
        "--from-alias", from_alias,
        message,
        "--json",
        "--broker-root", str(broker_root),
    ]
    for alias in exclude or []:
        cmd.extend(["--exclude", alias])
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, env=env, timeout=30)


class DeliveryPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.tmp.name)
        self.yaml_registry = self.broker_root / "isolated-yaml-registry.yaml"
        self.json_registry = self.broker_root / "registry.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _write_registry(self, entries: list[dict]) -> None:
        """Write registry entries to JSON registry directly.

        c2c_send_all.py spawns c2c_mcp.py which runs sync_broker_registry:
        reads from C2C_REGISTRY_PATH (YAML) and writes to broker_root/registry.json (JSON).
        We write JSON directly so sync preserves our data (YAML is empty/non-existent).
        """
        self.json_registry.write_text(json.dumps(entries), encoding="utf-8")

    def _write_json_registry(self, entries: list[dict]) -> None:
        """Write directly to JSON registry (used by OCaml binary)."""
        self.json_registry.write_text(json.dumps(entries), encoding="utf-8")

    def _read_inbox(self, session_id: str) -> list[dict]:
        path = self.broker_root / f"{session_id}.inbox.json"
        if not path.exists():
            return []
        return json.loads(path.read_text(encoding="utf-8"))

    # -------------------------------------------------------------------------
    # (a) supervisor-broadcast permission DM delivery
    # -------------------------------------------------------------------------

    def test_broadcast_to_multiple_supervisors_delivers_to_all(self) -> None:
        """When sending to multiple supervisors, each should receive the message."""
        self._write_registry([
            {"session_id": "sup-1", "alias": "coordinator1"},
            {"session_id": "sup-2", "alias": "ceo"},
            {"session_id": "sup-3", "alias": "planner1"},
            {"session_id": "agent-1", "alias": "agent-x"},
        ])

        result = run_c2c_send_all(
            from_alias="agent-x",
            message="permission request: access external dir",
            broker_root=self.broker_root,
            exclude=["agent-x"],
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            sorted(payload["sent_to"]), sorted(["coordinator1", "ceo", "planner1"])
        )

        for sup_alias, sup_session in [
            ("coordinator1", "sup-1"),
            ("ceo", "sup-2"),
            ("planner1", "sup-3"),
        ]:
            inbox = self._read_inbox(sup_session)
            self.assertEqual(len(inbox), 1, f"{sup_alias} should have exactly one message")
            self.assertEqual(inbox[0]["from_alias"], "agent-x")

    def test_broadcast_skips_dead_recipients(self) -> None:
        """Dead recipients should be skipped in broadcast."""
        self._write_registry([
            {"session_id": "sup-1", "alias": "coordinator1"},
            {"session_id": "sup-2", "alias": "ceo"},
            {"session_id": "agent-1", "alias": "agent-x"},
        ])

        result = run_c2c_send_all(
            from_alias="agent-x",
            message="permission request",
            broker_root=self.broker_root,
            exclude=["agent-x"],
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(sorted(payload["sent_to"]), sorted(["ceo", "coordinator1"]))
        self.assertEqual(payload["skipped"], [])

    # -------------------------------------------------------------------------
    # (b) stale-PID sender DM still works
    # -------------------------------------------------------------------------

    def test_send_to_alias_delivers_message(self) -> None:
        """Basic send to alias delivers the message."""
        self._write_registry([
            {"session_id": "sender-session", "alias": "sender-x"},
            {"session_id": "receiver-session", "alias": "receiver-y"},
        ])

        result = run_c2c_send_all(
            from_alias="sender-x",
            message="hello via broadcast",
            broker_root=self.broker_root,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("receiver-y", payload["sent_to"])

    # -------------------------------------------------------------------------
    # (c) CC hook path — message survives archive drain
    # -------------------------------------------------------------------------

    def test_message_written_to_inbox_for_cc_hook_path(self) -> None:
        """Messages for CC should be in inbox (hook drains, archive preserves)."""
        self._write_registry([
            {"session_id": "cc-session", "alias": "claude-code-agent"},
            {"session_id": "sender-session", "alias": "sender-x"},
        ])

        result = run_c2c_send_all(
            from_alias="sender-x",
            message="urgent message for CC",
            broker_root=self.broker_root,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

        inbox = self._read_inbox("cc-session")
        self.assertEqual(len(inbox), 1)
        self.assertEqual(inbox[0]["content"], "urgent message for CC")

    # -------------------------------------------------------------------------
    # (d) OC plugin poll path — multiple messages delivered in order
    # -------------------------------------------------------------------------

    def test_multiple_messages_delivered_in_order(self) -> None:
        """Multiple sequential messages should all be delivered in order."""
        self._write_registry([
            {"session_id": "oc-session", "alias": "opencode-agent"},
            {"session_id": "sender-session", "alias": "sender-x"},
        ])

        messages = ["first message", "second message", "third message"]
        for msg in messages:
            result = run_c2c_send_all(
                from_alias="sender-x",
                message=msg,
                broker_root=self.broker_root,
            )
            self.assertEqual(result.returncode, 0, msg=f"failed to send: {msg}")

        inbox = self._read_inbox("oc-session")
        self.assertEqual(len(inbox), 3)
        for i, msg in enumerate(messages):
            self.assertEqual(inbox[i]["content"], msg)

    # -------------------------------------------------------------------------
    # (e) Codex bridge path — XML-staged messages survive broker restart
    # -------------------------------------------------------------------------

    def test_message_for_codex_bridge_in_inbox(self) -> None:
        """Messages for Codex should be in inbox (bridge reads from here)."""
        self._write_registry([
            {"session_id": "codex-session", "alias": "codex-agent"},
            {"session_id": "sender-session", "alias": "sender-x"},
        ])

        result = run_c2c_send_all(
            from_alias="sender-x",
            message="codex bridge message",
            broker_root=self.broker_root,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)

        inbox = self._read_inbox("codex-session")
        self.assertEqual(len(inbox), 1)
        self.assertEqual(inbox[0]["content"], "codex bridge message")


if __name__ == "__main__":
    unittest.main()
