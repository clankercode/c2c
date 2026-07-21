import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_deliver_inbox


class ParseManagedServerRequestEventTests(unittest.TestCase):
    def test_parses_permissions_approval_request_event(self):
        event_json = json.dumps({
            "kind": "permissions_approval_request",
            "request_id": "req-123",
            "thread_id": "thread-abc",
            "turn_id": "turn-1",
            "item_id": "item-1",
            "server_name": "bash",
            "raw": {
                "permission": "bash",
                "command": "touch /tmp/test",
                "reason": "testing",
            },
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNotNone(result)
        self.assertEqual(result["kind"], "permissions_approval_request")
        self.assertEqual(result["request_id"], "req-123")
        self.assertEqual(result["thread_id"], "thread-abc")
        self.assertEqual(result["turn_id"], "turn-1")
        self.assertEqual(result["item_id"], "item-1")
        self.assertEqual(result["server_name"], "bash")
        self.assertEqual(result["permission"], "bash")
        self.assertEqual(result["command"], "touch /tmp/test")
        self.assertEqual(result["reason"], "testing")

    def test_preserves_requested_permissions_profile(self):
        permissions = {
            "network": {"enabled": True},
            "fileSystem": {"read": ["/tmp"], "write": ["/tmp/out"]},
        }
        event_json = json.dumps({
            "kind": "permissions_approval_request",
            "request_id": "req-perms",
            "raw": {
                "permissions": permissions,
                "reason": "testing",
            },
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNotNone(result)
        self.assertEqual(result["permissions"], permissions)

    def test_ignores_thread_resolved_event(self):
        event_json = json.dumps({
            "kind": "thread_resolved",
            "thread_id": "thread-abc",
            "source": "started",
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNone(result)

    def test_ignores_malformed_json(self):
        result = c2c_deliver_inbox.parse_managed_server_request_event("not valid json")
        self.assertIsNone(result)

    def test_ignores_empty_string(self):
        result = c2c_deliver_inbox.parse_managed_server_request_event("")
        self.assertIsNone(result)

    def test_ignores_unknown_kind(self):
        event_json = json.dumps({
            "kind": "unknown_event",
            "request_id": "req-123",
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNone(result)

    def test_missing_raw_field(self):
        event_json = json.dumps({
            "kind": "permissions_approval_request",
            "request_id": "req-456",
            "thread_id": "thread-xyz",
            "turn_id": "turn-2",
            "item_id": "item-2",
            "server_name": "shell",
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNotNone(result)
        self.assertEqual(result["request_id"], "req-456")
        self.assertEqual(result["permission"], "")

    def test_raw_as_string_not_json_object(self):
        event_json = json.dumps({
            "kind": "permissions_approval_request",
            "request_id": "req-789",
            "thread_id": "thread-foo",
            "turn_id": "turn-3",
            "item_id": "item-3",
            "server_name": "bash",
            "raw": json.dumps({"permission": "bash", "command": "echo hello"}),
        })
        result = c2c_deliver_inbox.parse_managed_server_request_event(event_json)
        self.assertIsNotNone(result)
        self.assertEqual(result["request_id"], "req-789")
        self.assertEqual(result["permission"], "bash")

    def test_drains_split_utf8_jsonl_event_across_reads(self):
        event_json = json.dumps({
            "kind": "permissions_approval_request",
            "request_id": "req-utf8",
            "thread_id": "thread-utf8",
            "turn_id": "turn-utf8",
            "item_id": "item-utf8",
            "server_name": "bash",
            "raw": {
                "permission": "bash",
                "command": "echo hello",
                "reason": "fix 🪨",
            },
        }, ensure_ascii=False).encode("utf-8") + b"\n"

        split_at = event_json.index("🪨".encode("utf-8")) + 1
        first_buffer, first_events = c2c_deliver_inbox.drain_managed_server_request_events(
            b"", event_json[:split_at]
        )
        self.assertEqual(first_events, [])
        self.assertTrue(first_buffer)

        second_buffer, second_events = c2c_deliver_inbox.drain_managed_server_request_events(
            first_buffer, event_json[split_at:]
        )
        self.assertEqual(second_buffer, b"")
        self.assertEqual(len(second_events), 1)
        self.assertEqual(second_events[0]["request_id"], "req-utf8")
        self.assertEqual(second_events[0]["reason"], "fix 🪨")


class ForwardPermissionToSupervisorsTests(unittest.TestCase):
    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_opens_pending_reply_and_sends_dm(self, mock_run_c2c):
        mock_run_c2c.return_value = (0, "", "")
        event = {
            "kind": "permissions_approval_request",
            "request_id": "req-456",
            "thread_id": "thread-xyz",
            "permission": "bash",
            "command": "rm -rf /tmp/test",
            "reason": "cleanup",
        }
        result = c2c_deliver_inbox.forward_permission_to_supervisors(
            event, supervisors=["coordinator1"], timeout_ms=5000,
        )
        calls = mock_run_c2c.call_args_list
        call_args = [c[0][0] for c in calls]
        self.assertTrue(any("open-pending-reply" in c for c in call_args))
        self.assertTrue(any("send" in c[0] if isinstance(c, tuple) else "send" in c for c in call_args))
        self.assertTrue(any("coordinator1" in str(c) for c in call_args))

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    @mock.patch("c2c_deliver_inbox.await_supervisor_reply")
    def test_returns_approve_once_on_supervisor_reply(self, mock_await, mock_run_c2c):
        mock_run_c2c.return_value = (0, "", "")
        mock_await.return_value = "approve-once"
        event = {
            "kind": "permissions_approval_request",
            "request_id": "req-456",
            "thread_id": "thread-xyz",
            "permission": "bash",
            "command": "echo hello",
            "reason": "test",
        }
        result = c2c_deliver_inbox.forward_permission_to_supervisors(
            event, supervisors=["coordinator1"], timeout_ms=5000,
            session_id="test-session", broker_root=Path("/tmp"),
        )
        self.assertEqual(result, "approve-once")

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    @mock.patch("c2c_deliver_inbox.await_supervisor_reply")
    def test_returns_timeout_when_no_reply(self, mock_await, mock_run_c2c):
        mock_run_c2c.return_value = (0, "", "")
        mock_await.return_value = "timeout"
        event = {
            "kind": "permissions_approval_request",
            "request_id": "req-789",
            "thread_id": "thread-abc",
            "permission": "shell",
            "command": "cat /etc/passwd",
            "reason": "audit",
        }
        result = c2c_deliver_inbox.forward_permission_to_supervisors(
            event, supervisors=["coordinator1", "jungle-coder"], timeout_ms=1000,
            session_id="test-session", broker_root=Path("/tmp"),
        )
        self.assertEqual(result, "timeout")


class AwaitSupervisorReplyTests(unittest.TestCase):
    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_returns_decision_on_matching_reply(self, mock_run_c2c):
        mock_run_c2c.side_effect = [
            (0, json.dumps([
                {"from_alias": "coordinator1", "content": "permission:codex-req-123:approve-once"},
            ]), ""),
        ]
        result = c2c_deliver_inbox.await_supervisor_reply(
            "codex-req-123", 5000, ["coordinator1"], "test-session", Path("/tmp"),
        )
        self.assertEqual(result, "approve-once")

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_returns_timeout_when_no_matching_reply(self, mock_run_c2c):
        mock_run_c2c.side_effect = [
            (0, json.dumps([{"from_alias": "coordinator1", "content": "hello"}]), ""),
            (0, json.dumps([]), ""),
            (0, json.dumps([]), ""),
            (0, json.dumps([]), ""),
        ]
        result = c2c_deliver_inbox.await_supervisor_reply(
            "codex-req-456", 3000, ["coordinator1"], "test-session", Path("/tmp"),
        )
        self.assertEqual(result, "timeout")

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_returns_approve_always(self, mock_run_c2c):
        mock_run_c2c.return_value = (
            0,
            json.dumps([{"from_alias": "jungle-coder", "content": "permission:codex-req-789:approve-always"}]),
            "",
        )
        result = c2c_deliver_inbox.await_supervisor_reply(
            "codex-req-789", 5000, ["coordinator1", "jungle-coder"], "test-session", Path("/tmp"),
        )
        self.assertEqual(result, "approve-always")

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_ignores_reply_from_non_supervisor(self, mock_run_c2c):
        mock_run_c2c.side_effect = [
            (0, json.dumps([
                {"from_alias": "random-alias", "content": "permission:codex-req-999:approve-once"},
            ]), ""),
            (0, json.dumps([
                {"from_alias": "coordinator1", "content": "permission:codex-req-999:reject"},
            ]), ""),
        ]
        result = c2c_deliver_inbox.await_supervisor_reply(
            "codex-req-999", 3000, ["coordinator1"], "test-session", Path("/tmp"),
        )
        self.assertEqual(result, "reject")


class RunC2cCommandTests(unittest.TestCase):
    @mock.patch("subprocess.run")
    def test_returns_tuple(self, mock_run):
        mock_run.return_value = mock.Mock(returncode=0, stdout="ok", stderr="")
        with mock.patch("c2c_deliver_inbox._find_c2c_binary", return_value="c2c"):
            result = c2c_deliver_inbox.run_c2c_command(["whoami"])
            self.assertIsInstance(result, tuple)
            self.assertEqual(len(result), 3)
            self.assertEqual(result[0], 0)
            self.assertEqual(result[1], "ok")
            self.assertEqual(result[2], "")

    @mock.patch("subprocess.run")
    def test_uses_binary_from_find(self, mock_run):
        mock_run.return_value = mock.Mock(returncode=0, stdout="ok", stderr="")
        with mock.patch("c2c_deliver_inbox._find_c2c_binary", return_value="/custom/bin/c2c"):
            c2c_deliver_inbox.run_c2c_command(["whoami"])
            mock_run.assert_called_once()
            call_cmd = mock_run.call_args[0][0]
            self.assertEqual(call_cmd[0], "/custom/bin/c2c")


class SendCallFixTests(unittest.TestCase):
    """send call must not use --content flag (unknown option in OCaml c2c send)."""

    @mock.patch("c2c_deliver_inbox.run_c2c_command")
    def test_send_uses_positional_message_not_content_flag(self, mock_run_c2c):
        mock_run_c2c.return_value = (0, "", "")
        event = {
            "kind": "permissions_approval_request",
            "request_id": "req-send",
            "thread_id": "thread-1",
            "permission": "bash",
            "command": "echo hi",
            "reason": "test",
        }
        c2c_deliver_inbox.forward_permission_to_supervisors(
            event, supervisors=["coordinator1"], timeout_ms=1000,
        )
        send_calls = [
            c[0][0] for c in mock_run_c2c.call_args_list
            if len(c[0][0]) > 0 and c[0][0][0] == "send"
        ]
        self.assertTrue(len(send_calls) > 0, "expected at least one send call")
        for args in send_calls:
            self.assertNotIn("--content", args, "send must not use --content flag")
            # Message body should be at position 2 (after "send" and alias)
            self.assertGreaterEqual(len(args), 3, "send args should be: send <alias> <msg>")


class WritePermissionResponseTests(unittest.TestCase):
    def _write_and_read_response(self, event, decision):
        import tempfile, os
        with tempfile.TemporaryDirectory() as tmpdir:
            fifo = Path(tmpdir) / "resp.fifo"
            os.mkfifo(str(fifo))
            rfd = os.open(str(fifo), os.O_RDONLY | os.O_NONBLOCK)
            try:
                c2c_deliver_inbox.write_permission_response(fifo, event, decision)
                data = os.read(rfd, 4096)
            finally:
                os.close(rfd)
            return json.loads(data.decode())

    def test_writes_turn_scoped_sideband_response_on_approve_once(self):
        event = {
            "request_id": "req-1",
            "permissions": {
                "network": {"enabled": True},
                "fileSystem": {"read": ["/tmp"], "write": ["/tmp/out"]},
            },
        }
        payload = self._write_and_read_response(event, "approve-once")
        self.assertEqual(payload["request_id"], "req-1")
        self.assertEqual(payload["kind"], "permissions_approval_response")
        self.assertNotIn("raw", payload)
        self.assertEqual(payload["response"]["scope"], "turn")
        self.assertEqual(payload["response"]["permissions"], event["permissions"])

    def test_writes_session_scoped_sideband_response_on_approve_always(self):
        event = {
            "request_id": "req-2",
            "permissions": {"network": {"enabled": True}},
        }
        payload = self._write_and_read_response(event, "approve-always")
        self.assertEqual(payload["response"]["scope"], "session")
        self.assertEqual(payload["response"]["permissions"], event["permissions"])

    def test_writes_empty_permissions_on_reject(self):
        event = {
            "request_id": "req-3",
            "permissions": {"network": {"enabled": True}},
        }
        payload = self._write_and_read_response(event, "reject")
        self.assertEqual(payload["response"]["scope"], "turn")
        self.assertEqual(payload["response"]["permissions"], {})

    def test_writes_empty_permissions_on_timeout(self):
        event = {
            "request_id": "req-4",
            "permissions": {"network": {"enabled": True}},
        }
        payload = self._write_and_read_response(event, "timeout")
        self.assertEqual(payload["response"]["scope"], "turn")
        self.assertEqual(payload["response"]["permissions"], {})

    def test_no_op_when_fifo_is_none(self):
        event = {"request_id": "req-4", "permission": "bash"}
        # Should not raise
        c2c_deliver_inbox.write_permission_response(None, event, "approve-once")


if __name__ == "__main__":
    unittest.main()
