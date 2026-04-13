import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_deliver_inbox


class C2CDeliverInboxLoopTests(unittest.TestCase):
    def test_loop_runs_until_max_iterations_and_sleeps_between_empty_polls(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_target",
                    return_value=(33333, "9", None),
                ),
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    side_effect=[
                        {
                            "ok": True,
                            "messages": [],
                            "delivered": 0,
                            "dry_run": False,
                        },
                        {
                            "ok": True,
                            "messages": [
                                {
                                    "from_alias": "storm-echo",
                                    "to_alias": "codex",
                                    "content": "wake",
                                }
                            ],
                            "delivered": 1,
                            "dry_run": False,
                        },
                    ],
                ) as deliver_once,
                mock.patch("c2c_deliver_inbox.pid_is_alive", return_value=True),
                mock.patch("c2c_deliver_inbox.time.sleep") as sleep,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--broker-root",
                        str(broker_root),
                        "--loop",
                        "--max-iterations",
                        "2",
                        "--interval",
                        "0.25",
                        "--json",
                    ]
                )

            self.assertEqual(result, 0)
            self.assertEqual(deliver_once.call_count, 2)
            sleep.assert_called_once_with(0.25)

    def test_loop_writes_pidfile_before_first_iteration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            pidfile = Path(temp_dir) / "deliver.pid"

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_target",
                    return_value=(33333, "9", None),
                ),
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    return_value={
                        "ok": True,
                        "messages": [],
                        "delivered": 0,
                        "dry_run": False,
                    },
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--broker-root",
                        str(broker_root),
                        "--loop",
                        "--max-iterations",
                        "1",
                        "--pidfile",
                        str(pidfile),
                    ]
                )

            self.assertEqual(result, 0)
            self.assertTrue(pidfile.exists())
            self.assertRegex(pidfile.read_text(encoding="utf-8"), r"^\d+\n$")

    def test_loop_exits_without_delivering_when_watched_pid_is_dead(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_target",
                    return_value=(33333, "9", None),
                ),
                mock.patch("c2c_deliver_inbox.pid_is_alive", return_value=False),
                mock.patch("c2c_deliver_inbox.deliver_once") as deliver_once,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--broker-root",
                        str(broker_root),
                        "--loop",
                        "--json",
                    ]
                )

            self.assertEqual(result, 0)
            deliver_once.assert_not_called()

    def test_daemon_reuses_running_pidfile_without_spawning(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            pidfile = Path(temp_dir) / "deliver.pid"
            log_path = Path(temp_dir) / "deliver.log"
            pidfile.write_text("4242\n", encoding="utf-8")

            with (
                mock.patch("c2c_deliver_inbox.pid_is_alive", return_value=True),
                mock.patch("c2c_deliver_inbox.subprocess.Popen") as popen,
            ):
                result = c2c_deliver_inbox.start_daemon(
                    child_argv=["--client", "codex", "--pid", "12345", "--loop"],
                    pidfile=pidfile,
                    log_path=log_path,
                    wait_timeout=0.1,
                )

            self.assertTrue(result["ok"])
            self.assertTrue(result["already_running"])
            self.assertEqual(result["pid"], 4242)
            popen.assert_not_called()

    def test_daemon_starts_child_and_waits_for_pidfile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            pidfile = Path(temp_dir) / "deliver.pid"
            log_path = Path(temp_dir) / "deliver.log"
            proc = mock.Mock(pid=5151)
            proc.poll.return_value = None

            def write_pidfile(_seconds):
                pidfile.write_text("5151\n", encoding="utf-8")

            with (
                mock.patch("c2c_deliver_inbox.pid_is_alive", return_value=False),
                mock.patch("c2c_deliver_inbox.subprocess.Popen", return_value=proc)
                as popen,
                mock.patch("c2c_deliver_inbox.time.sleep", side_effect=write_pidfile),
            ):
                result = c2c_deliver_inbox.start_daemon(
                    child_argv=["--client", "codex", "--pid", "12345", "--loop"],
                    pidfile=pidfile,
                    log_path=log_path,
                    wait_timeout=1.0,
                )

            self.assertTrue(result["ok"])
            self.assertFalse(result["already_running"])
            self.assertEqual(result["pid"], 5151)
            command = popen.call_args.args[0]
            self.assertEqual(command[0], sys.executable)
            self.assertIn("--loop", command)
            self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_main_daemon_starts_before_resolving_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            pidfile = Path(temp_dir) / "deliver.pid"
            with (
                mock.patch(
                    "c2c_deliver_inbox.start_daemon",
                    return_value={
                        "ok": True,
                        "daemon": True,
                        "pid": 6161,
                        "already_running": False,
                    },
                ) as start_daemon,
                mock.patch("c2c_deliver_inbox.c2c_inject.resolve_target") as resolve,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--loop",
                        "--daemon",
                        "--pidfile",
                        str(pidfile),
                        "--json",
                    ]
                )

            self.assertEqual(result, 0)
            start_daemon.assert_called_once()
            resolve.assert_not_called()


if __name__ == "__main__":
    unittest.main()
