import unittest
from unittest import mock

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_opencode_wake_daemon


class OpenCodeWakeDaemonTests(unittest.TestCase):
    """pty_inject() is a thin wrapper over c2c_pty_inject.inject(); these
    tests assert the arguments are forwarded correctly and failure paths
    surface as False, not as uncaught exceptions."""

    def test_pty_inject_forwards_submit_delay_to_backend(self):
        with mock.patch(
            "c2c_opencode_wake_daemon.c2c_pty_inject.inject",
            return_value=None,
        ) as inject:
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=5.0,
            )

        self.assertTrue(result)
        inject.assert_called_once_with(3725367, 22, "wake", submit_delay=5.0)

    def test_pty_inject_forwards_none_submit_delay(self):
        with mock.patch(
            "c2c_opencode_wake_daemon.c2c_pty_inject.inject",
            return_value=None,
        ) as inject:
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=None,
            )

        self.assertTrue(result)
        inject.assert_called_once_with(3725367, 22, "wake", submit_delay=None)

    def test_pty_inject_reports_backend_failure_as_false(self):
        with mock.patch(
            "c2c_opencode_wake_daemon.c2c_pty_inject.inject",
            side_effect=PermissionError("need cap_sys_ptrace"),
        ):
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=False,
                submit_delay=2.5,
            )

        self.assertFalse(result)

    def test_pty_inject_dry_run_does_not_call_backend(self):
        with mock.patch(
            "c2c_opencode_wake_daemon.c2c_pty_inject.inject",
        ) as inject:
            result = c2c_opencode_wake_daemon.pty_inject(
                3725367,
                22,
                "wake",
                dry_run=True,
                submit_delay=None,
            )

        self.assertTrue(result)
        inject.assert_not_called()


if __name__ == "__main__":
    unittest.main()
