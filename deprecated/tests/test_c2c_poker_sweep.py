import io
import json
import unittest
from unittest import mock

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_cli
import c2c_install
import c2c_poker_sweep


class C2CPokerSweepTests(unittest.TestCase):
    def test_classifies_pid_poker_as_stale_when_watched_pid_is_dead(self):
        process = c2c_poker_sweep.PokerProcess(
            pid=111,
            argv=["python3", "c2c_poker.py", "--pid", "222", "--interval", "600"],
        )

        with mock.patch("c2c_poker_sweep.pid_is_alive", return_value=False):
            result = c2c_poker_sweep.classify_process(process, claude_sessions=[])

        self.assertFalse(result["live"])
        self.assertEqual(result["reason"], "watched_pid_dead")
        self.assertEqual(result["watched_pid"], 222)

    def test_classifies_claude_poker_as_stale_when_session_is_missing(self):
        process = c2c_poker_sweep.PokerProcess(
            pid=111,
            argv=[
                "python3",
                "c2c_poker.py",
                "--claude-session",
                "storm-beacon",
            ],
        )

        result = c2c_poker_sweep.classify_process(process, claude_sessions=[])

        self.assertFalse(result["live"])
        self.assertEqual(result["reason"], "claude_session_missing")

    def test_sweep_does_not_kill_without_kill_flag(self):
        process = c2c_poker_sweep.PokerProcess(
            pid=111,
            argv=["python3", "c2c_poker.py", "--pid", "222"],
        )

        with (
            mock.patch("c2c_poker_sweep.pid_is_alive", return_value=False),
            mock.patch("c2c_poker_sweep.kill_process") as kill_process,
        ):
            result = c2c_poker_sweep.sweep_processes(
                [process], claude_sessions=[], kill_stale=False
            )

        self.assertEqual(result["stale"], 1)
        self.assertFalse(result["processes"][0]["killed"])
        kill_process.assert_not_called()

    def test_sweep_kills_stale_process_with_kill_flag(self):
        process = c2c_poker_sweep.PokerProcess(
            pid=111,
            argv=["python3", "c2c_poker.py", "--pid", "222"],
        )

        with (
            mock.patch("c2c_poker_sweep.pid_is_alive", return_value=False),
            mock.patch("c2c_poker_sweep.kill_process") as kill_process,
        ):
            result = c2c_poker_sweep.sweep_processes(
                [process], claude_sessions=[], kill_stale=True
            )

        self.assertEqual(result["killed"], 1)
        self.assertTrue(result["processes"][0]["killed"])
        kill_process.assert_called_once_with(111)

    def test_main_emits_json(self):
        process = c2c_poker_sweep.PokerProcess(
            pid=111,
            argv=["python3", "c2c_poker.py", "--pid", "222"],
        )

        with (
            mock.patch("c2c_poker_sweep.list_poker_processes", return_value=[process]),
            mock.patch("c2c_poker_sweep.c2c_poker.list_claude_sessions", return_value=[]),
            mock.patch("c2c_poker_sweep.pid_is_alive", return_value=False),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            result = c2c_poker_sweep.main(["--json"])

        self.assertEqual(result, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["stale"], 1)

    def test_cli_dispatches_poker_sweep(self):
        with mock.patch("c2c_cli.c2c_poker_sweep.main", return_value=0) as main:
            result = c2c_cli.main(["poker-sweep", "--json"])

        self.assertEqual(result, 0)
        main.assert_called_once_with(["--json"])

    def test_install_includes_poker_sweep_wrapper(self):
        self.assertIn("c2c-poker-sweep", c2c_install.COMMANDS)


if __name__ == "__main__":
    unittest.main()
