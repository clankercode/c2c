import json
import os
import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
