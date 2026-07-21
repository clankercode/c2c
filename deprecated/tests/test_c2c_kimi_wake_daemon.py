import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_kimi_wake_daemon


class KimiWakeDaemonPtyInjectTests(unittest.TestCase):
    def test_wake_inject_uses_master_pty_with_default_delay(self):
        with mock.patch("c2c_kimi_wake_daemon.c2c_poker.inject") as mock_inject:
            result = c2c_kimi_wake_daemon.wake_inject(
                terminal_pid=44444,
                pts=7,
                message="wake up",
                dry_run=False,
            )

        self.assertTrue(result)
        mock_inject.assert_called_once_with(44444, "7", "wake up", submit_delay=1.5)

    def test_wake_inject_dry_run_skips_inject(self):
        with mock.patch("c2c_kimi_wake_daemon.c2c_poker.inject") as mock_inject:
            result = c2c_kimi_wake_daemon.wake_inject(
                terminal_pid=44444,
                pts=7,
                message="wake up",
                dry_run=True,
            )

        self.assertTrue(result)
        mock_inject.assert_not_called()

    def test_wake_inject_returns_false_on_exception(self):
        with mock.patch("c2c_kimi_wake_daemon.c2c_poker.inject") as mock_inject:
            mock_inject.side_effect = PermissionError("permission denied")
            result = c2c_kimi_wake_daemon.wake_inject(
                terminal_pid=44444,
                pts=7,
                message="wake up",
                dry_run=False,
            )

        self.assertFalse(result)

    def test_wake_inject_does_not_use_pts_slave_writer(self):
        with (
            mock.patch("c2c_kimi_wake_daemon.c2c_poker.inject") as mock_inject,
            mock.patch("c2c_kimi_wake_daemon.c2c_pts_inject.inject") as pts_inject,
        ):
            c2c_kimi_wake_daemon.wake_inject(
                terminal_pid=44444,
                pts=7,
                message="wake up",
                dry_run=False,
            )

        mock_inject.assert_called_once()
        pts_inject.assert_not_called()


class KimiWakeDaemonInboxTests(unittest.TestCase):
    def test_inbox_has_messages_returns_true_for_nonempty(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "kimi.inbox.json"
            p.write_text(
                json.dumps([{"from_alias": "storm-beacon", "to_alias": "kimi-nova", "content": "hi"}]),
                encoding="utf-8",
            )
            self.assertTrue(c2c_kimi_wake_daemon.inbox_has_messages(p))

    def test_inbox_has_messages_returns_false_for_empty_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "kimi.inbox.json"
            p.write_text("[]", encoding="utf-8")
            self.assertFalse(c2c_kimi_wake_daemon.inbox_has_messages(p))

    def test_inbox_has_messages_returns_false_for_missing_file(self):
        p = Path("/tmp/nonexistent-c2c-test-inbox.json")
        self.assertFalse(c2c_kimi_wake_daemon.inbox_has_messages(p))

    def test_inbox_has_messages_returns_false_for_blank(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "kimi.inbox.json"
            p.write_text("", encoding="utf-8")
            self.assertFalse(c2c_kimi_wake_daemon.inbox_has_messages(p))


if __name__ == "__main__":
    unittest.main()
