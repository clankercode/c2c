import io
import unittest
from unittest import mock

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_poker


class C2CPokerWatchPidTests(unittest.TestCase):
    def test_main_exits_without_injecting_when_watched_pid_is_dead(self):
        argv = [
            "c2c_poker.py",
            "--pid",
            "12345",
            "--interval",
            "600",
            "--message",
            "wake",
            "--once",
        ]

        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch("c2c_poker.resolve_pid", return_value=(33333, "9", None)),
            mock.patch("c2c_poker.pid_is_alive", return_value=False),
            mock.patch("c2c_poker.inject") as inject,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            result = c2c_poker.main()

        self.assertEqual(result, 0)
        inject.assert_not_called()

    def test_main_includes_send_date_in_injected_payload(self):
        argv = [
            "c2c_poker.py",
            "--pid",
            "12345",
            "--event",
            "heartbeat",
            "--from",
            "codex-poker",
            "--alias",
            "codex",
            "--message",
            "wake",
            "--once",
        ]

        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch("c2c_poker.resolve_pid", return_value=(33333, "9", None)),
            mock.patch("c2c_poker.pid_is_alive", return_value=True),
            mock.patch(
                "c2c_poker.current_send_date",
                return_value="2026-04-13 15:12:00 AEST",
            ),
            mock.patch("c2c_poker.inject") as inject,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            result = c2c_poker.main()

        self.assertEqual(result, 0)
        payload = inject.call_args.args[2]
        self.assertIn("wake", payload)
        self.assertIn("Sent at: 2026-04-13 15:12:00 AEST", payload)


if __name__ == "__main__":
    unittest.main()
