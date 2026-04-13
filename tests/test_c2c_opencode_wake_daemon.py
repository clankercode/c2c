import subprocess
import unittest
from unittest import mock

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_opencode_wake_daemon


class OpenCodeWakeDaemonTests(unittest.TestCase):
    def test_pty_inject_passes_submit_delay_to_helper(self):
        success = subprocess.CompletedProcess(args=["pty_inject"], returncode=0)
        with mock.patch(
            "c2c_opencode_wake_daemon.subprocess.run",
            return_value=success,
        ) as run:
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=5.0,
            )

        self.assertTrue(result)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[-2:], ["wake", "5"])
        self.assertGreater(run.call_args.kwargs["timeout"], 5.0)

    def test_pty_inject_uses_default_helper_delay_when_submit_delay_is_none(self):
        success = subprocess.CompletedProcess(args=["pty_inject"], returncode=0)
        with mock.patch(
            "c2c_opencode_wake_daemon.subprocess.run",
            return_value=success,
        ) as run:
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=None,
            )

        self.assertTrue(result)
        command = run.call_args.args[0]
        self.assertEqual(command[-1], "wake")

    def test_pty_inject_reports_helper_failure(self):
        failed = subprocess.CompletedProcess(
            args=["pty_inject"],
            returncode=1,
            stdout="",
            stderr="bad delay\n",
        )
        with mock.patch(
            "c2c_opencode_wake_daemon.subprocess.run",
            return_value=failed,
        ):
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=2.5,
            )

        self.assertFalse(result)


if __name__ == "__main__":
    unittest.main()
