"""Tests for c2c_wire_daemon: start/stop/status/list lifecycle management."""
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock as mock
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_wire_daemon as wd


class WireDaemonStatusTests(unittest.TestCase):
    def test_status_not_running_when_no_pidfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(wd, "_state_dir", return_value=Path(tmp)):
                status = wd._daemon_status("kimi-test")
        self.assertFalse(status["running"])
        self.assertIsNone(status["pid"])

    def test_status_running_when_pidfile_has_live_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            pidfile = state / "kimi-test.pid"
            pidfile.write_text(f"{os.getpid()}\n", encoding="utf-8")

            with mock.patch.object(wd, "_state_dir", return_value=state):
                status = wd._daemon_status("kimi-test")

        self.assertTrue(status["running"])
        self.assertEqual(status["pid"], os.getpid())

    def test_status_not_running_when_pidfile_has_dead_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            pidfile = state / "kimi-test.pid"
            pidfile.write_text("999999999\n", encoding="utf-8")

            with mock.patch.object(wd, "_state_dir", return_value=state):
                status = wd._daemon_status("kimi-test")

        self.assertFalse(status["running"])
        self.assertEqual(status["pid"], 999999999)


class WireDaemonStartTests(unittest.TestCase):
    def test_start_delegates_to_start_daemon(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)

            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch(
                    "c2c_wire_daemon.c2c_kimi_wire_bridge.start_daemon",
                    return_value={"ok": True, "already_running": False, "pid": 8080},
                ) as start_daemon,
                mock.patch("sys.stdout", new_callable=io.StringIO),
                mock.patch("c2c_wire_daemon.c2c_poll_inbox.default_broker_root",
                           return_value=tmp),
            ):
                rc = wd.main(["start", "--session-id", "kimi-test"])

        self.assertEqual(rc, 0)
        start_daemon.assert_called_once()
        call_kwargs = start_daemon.call_args.kwargs
        self.assertEqual(call_kwargs["pidfile"], state / "kimi-test.pid")
        self.assertIn("--session-id", call_kwargs["child_argv"])

    def test_start_already_running_still_returns_0(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)

            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch(
                    "c2c_wire_daemon.c2c_kimi_wire_bridge.start_daemon",
                    return_value={"ok": True, "already_running": True, "pid": 8081},
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO),
                mock.patch("c2c_wire_daemon.c2c_poll_inbox.default_broker_root",
                           return_value=tmp),
            ):
                rc = wd.main(["start", "--session-id", "kimi-test"])

        self.assertEqual(rc, 0)


class WireDaemonStopTests(unittest.TestCase):
    def test_stop_sends_sigterm_to_live_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            pidfile = state / "kimi-test.pid"
            pidfile.write_text("12345\n", encoding="utf-8")

            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch("c2c_wire_daemon._pid_is_alive", return_value=True),
                mock.patch("c2c_wire_daemon.os.kill") as kill,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                rc = wd.main(["stop", "--session-id", "kimi-test"])

        self.assertEqual(rc, 0)
        import signal
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertFalse(pidfile.exists())

    def test_stop_returns_0_when_not_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)

            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                rc = wd.main(["stop", "--session-id", "kimi-not-running"])

        self.assertEqual(rc, 0)


class WireDaemonListTests(unittest.TestCase):
    def test_list_empty_when_no_state_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "nonexistent"

            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                rc = wd.main(["list"])

        self.assertEqual(rc, 0)

    def test_list_json_includes_all_pidfiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "kimi-a.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
            (state / "kimi-b.pid").write_text("999999999\n", encoding="utf-8")

            buf = io.StringIO()
            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch("sys.stdout", buf),
            ):
                rc = wd.main(["list", "--json"])

        self.assertEqual(rc, 0)
        statuses = json.loads(buf.getvalue())
        ids = [s["session_id"] for s in statuses]
        self.assertIn("kimi-a", ids)
        self.assertIn("kimi-b", ids)


class WireDaemonCLITests(unittest.TestCase):
    def test_no_subcommand_returns_2(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = wd.main([])
        self.assertEqual(rc, 2)

    def test_status_json_for_not_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)

            buf = io.StringIO()
            with (
                mock.patch.object(wd, "_state_dir", return_value=state),
                mock.patch("sys.stdout", buf),
            ):
                rc = wd.main(["status", "--session-id", "kimi-gone", "--json"])

        self.assertEqual(rc, 0)
        data = json.loads(buf.getvalue())
        self.assertFalse(data["running"])
        self.assertEqual(data["session_id"], "kimi-gone")


if __name__ == "__main__":
    unittest.main()
