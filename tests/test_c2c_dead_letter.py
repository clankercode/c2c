"""Regression tests for c2c_dead_letter.py --replay.

Verifies that the replay escape hatch:
1. Parses dead-letter.jsonl entries correctly
2. Filters by to_alias and from_session_id
3. Calls c2c_send.send_to_alias for each filtered record
4. Skips records that lack a to_alias with an error
5. Handles dry-run mode (no sends, just prints)
6. Does not modify the dead-letter file
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_dead_letter


def _make_entry(
    to_alias: str,
    content: str,
    from_alias: str = "sender",
    from_session_id: str = "sid-sender",
    deleted_at: float = 1_000_000.0,
) -> dict:
    return {
        "deleted_at": deleted_at,
        "from_session_id": from_session_id,
        "message": {
            "to_alias": to_alias,
            "from_alias": from_alias,
            "content": content,
        },
    }


def _write_dl(records: list[dict], path: Path) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec) + "\n")


class FilterTests(unittest.TestCase):
    """Unit tests for filter_records."""

    def test_no_filter_returns_all(self):
        records = [
            _make_entry("alice", "msg1"),
            _make_entry("bob", "msg2"),
        ]
        result = c2c_dead_letter.filter_records(records, to_alias=None, from_sid=None)
        self.assertEqual(len(result), 2)

    def test_filter_by_to_alias(self):
        records = [
            _make_entry("alice", "msg1"),
            _make_entry("bob", "msg2"),
            _make_entry("alice", "msg3"),
        ]
        result = c2c_dead_letter.filter_records(
            records, to_alias="alice", from_sid=None
        )
        self.assertEqual(len(result), 2)
        for r in result:
            self.assertEqual(r["message"]["to_alias"], "alice")

    def test_filter_by_from_sid(self):
        records = [
            _make_entry("alice", "msg1", from_session_id="sid-a"),
            _make_entry("bob", "msg2", from_session_id="sid-b"),
        ]
        result = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid="sid-a"
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["from_session_id"], "sid-a")

    def test_combined_filters(self):
        records = [
            _make_entry("alice", "msg1", from_session_id="sid-a"),
            _make_entry("bob", "msg2", from_session_id="sid-a"),
            _make_entry("alice", "msg3", from_session_id="sid-b"),
        ]
        result = c2c_dead_letter.filter_records(
            records, to_alias="alice", from_sid="sid-a"
        )
        self.assertEqual(len(result), 1)


class ReplayTests(unittest.TestCase):
    """End-to-end replay tests using a temp dead-letter file."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dl_path = Path(self._tmp.name) / "dead-letter.jsonl"
        self.broker_root = Path(self._tmp.name) / "broker"
        self.broker_root.mkdir()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _send_mock(self, to_alias: str, content: str, dry_run: bool = False) -> dict:
        return {"queued": True, "to": to_alias}

    def test_replay_calls_send_to_alias_for_each_filtered_record(self):
        records = [
            _make_entry("alice", "dead-msg-1"),
            _make_entry("bob", "dead-msg-2"),
            _make_entry("alice", "dead-msg-3"),
        ]
        _write_dl(records, self.dl_path)
        filtered = c2c_dead_letter.filter_records(
            records, to_alias="alice", from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=self._send_mock
        ) as send_mock:
            summary = c2c_dead_letter.replay_records(
                filtered, dry_run=False, broker_root=self.broker_root
            )
        self.assertEqual(send_mock.call_count, 2)
        for call in send_mock.call_args_list:
            self.assertEqual(call[0][0], "alice")

    def test_replay_skips_records_without_to_alias(self):
        records = [
            {"deleted_at": 1_000_000.0, "from_session_id": "sid-x", "message": {}},
            _make_entry("alice", "good-msg"),
        ]
        _write_dl(records, self.dl_path)
        filtered = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=self._send_mock
        ) as send_mock:
            summary = c2c_dead_letter.replay_records(
                filtered, dry_run=False, broker_root=self.broker_root
            )
        # Only the record with to_alias should be sent
        self.assertEqual(send_mock.call_count, 1)
        self.assertIn("skipped", summary)

    def test_replay_dry_run_does_not_call_send(self):
        records = [_make_entry("alice", "dry-msg")]
        _write_dl(records, self.dl_path)
        filtered = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=self._send_mock
        ) as send_mock:
            summary = c2c_dead_letter.replay_records(
                filtered, dry_run=True, broker_root=self.broker_root
            )
        send_mock.assert_not_called()
        self.assertEqual(summary["sent"], 0)

    def test_replay_does_not_modify_dead_letter_file(self):
        records = [_make_entry("alice", "intact-msg")]
        _write_dl(records, self.dl_path)
        original_content = self.dl_path.read_text()
        filtered = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=self._send_mock
        ):
            c2c_dead_letter.replay_records(
                filtered, dry_run=False, broker_root=self.broker_root
            )
        self.assertEqual(self.dl_path.read_text(), original_content)

    def test_replay_returns_correct_summary(self):
        records = [
            _make_entry("alice", "msg-a"),
            _make_entry("bob", "msg-b"),
        ]
        _write_dl(records, self.dl_path)
        filtered = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=self._send_mock
        ):
            summary = c2c_dead_letter.replay_records(
                filtered, dry_run=False, broker_root=self.broker_root
            )
        self.assertEqual(summary["sent"], 2)
        self.assertEqual(len(summary["failed"]), 0)

    def test_replay_handles_send_exception(self):
        records = [_make_entry("alice", "fails")]

        def failing_send(to_alias: str, content: str, dry_run: bool = False) -> dict:
            raise RuntimeError("broker unreachable")

        _write_dl(records, self.dl_path)
        filtered = c2c_dead_letter.filter_records(
            records, to_alias=None, from_sid=None
        )
        with mock.patch.object(
            c2c_dead_letter, "send_to_alias", side_effect=failing_send
        ):
            summary = c2c_dead_letter.replay_records(
                filtered, dry_run=False, broker_root=self.broker_root
            )
        self.assertEqual(len(summary["failed"]), 1)
        self.assertIn("broker unreachable", summary["failed"][0]["error"])


class LoadTests(unittest.TestCase):
    """Tests for load_records."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dl_path = Path(self._tmp.name) / "dead-letter.jsonl"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_load_empty_file(self):
        self.dl_path.write_text("", encoding="utf-8")
        self.assertEqual(c2c_dead_letter.load_records(self.dl_path), [])

    def test_load_missing_file(self):
        self.assertEqual(c2c_dead_letter.load_records(self.dl_path), [])

    def test_load_skips_blank_lines(self):
        self.dl_path.write_text("  \n{}\n  \n", encoding="utf-8")
        result = c2c_dead_letter.load_records(self.dl_path)
        self.assertEqual(len(result), 1)

    def test_load_skips malformed_lines(self):
        self.dl_path.write_text('{"ok":true}\nnot json\n{"to_alias":"x"}\n', encoding="utf-8")
        result = c2c_dead_letter.load_records(self.dl_path)
        self.assertEqual(len(result), 2)


if __name__ == "__main__":
    unittest.main()
