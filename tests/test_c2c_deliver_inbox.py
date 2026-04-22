import io
import json
import os
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
    def test_main_xml_output_fd_bypasses_terminal_resolution(self):
        read_fd, write_fd = os.pipe()
        try:
            with (
                mock.patch("c2c_deliver_inbox.c2c_inject.resolve_session_info") as resolve,
                mock.patch("c2c_deliver_inbox.deliver_once", return_value={"delivered": 0, "messages": [], "ok": True, "dry_run": False}),
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
                        "--xml-output-fd",
                        str(write_fd),
                        "--json",
                    ]
                )
        finally:
            os.close(read_fd)
            os.close(write_fd)

        self.assertEqual(result, 0)
        resolve.assert_not_called()

    def test_main_xml_output_fd_accepts_codex_headless_client(self):
        read_fd, write_fd = os.pipe()
        try:
            with (
                mock.patch("c2c_deliver_inbox.c2c_inject.resolve_session_info") as resolve,
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    return_value={"delivered": 0, "messages": [], "ok": True, "dry_run": False},
                ) as deliver_once,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex-headless",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-headless-local",
                        "--xml-output-fd",
                        str(write_fd),
                        "--json",
                    ]
                )
        finally:
            os.close(read_fd)
            os.close(write_fd)

        self.assertEqual(result, 0)
        resolve.assert_not_called()
        self.assertEqual(deliver_once.call_args.kwargs["client"], "codex-headless")
        self.assertEqual(deliver_once.call_args.kwargs["xml_output_fd"], write_fd)

    def test_main_xml_output_path_bypasses_terminal_resolution(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            xml_path = Path(temp_dir) / "xml-input.fifo"
            xml_path.touch()
            with (
                mock.patch("c2c_deliver_inbox.c2c_inject.resolve_session_info") as resolve,
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    return_value={"delivered": 0, "messages": [], "ok": True, "dry_run": False},
                ) as deliver_once,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex-headless",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-headless-local",
                        "--xml-output-path",
                        str(xml_path),
                        "--json",
                    ]
                )

        self.assertEqual(result, 0)
        resolve.assert_not_called()
        self.assertEqual(deliver_once.call_args.kwargs["client"], "codex-headless")
        self.assertEqual(deliver_once.call_args.kwargs["xml_output_path"], xml_path)

    def test_main_rejects_both_xml_output_fd_and_path(self):
        read_fd, write_fd = os.pipe()
        try:
            with (
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                with self.assertRaises(SystemExit) as exc:
                    c2c_deliver_inbox.main(
                        [
                            "--client",
                            "codex-headless",
                            "--pid",
                            "12345",
                            "--session-id",
                            "codex-headless-local",
                            "--xml-output-fd",
                            str(write_fd),
                            "--xml-output-path",
                            "/tmp/fifo",
                        ]
                    )
        finally:
            os.close(read_fd)
            os.close(write_fd)

        self.assertEqual(exc.exception.code, 2)
        self.assertIn("mutually exclusive", stderr.getvalue())

    def test_loop_runs_until_max_iterations_and_sleeps_between_empty_polls(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_session_info",
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
                    "c2c_deliver_inbox.c2c_inject.resolve_session_info",
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
                    "c2c_deliver_inbox.c2c_inject.resolve_session_info",
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
                mock.patch("c2c_deliver_inbox.c2c_inject.resolve_session_info") as resolve,
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

    def test_main_reports_target_resolution_errors(self):
        with (
            mock.patch(
                "c2c_deliver_inbox.c2c_inject.resolve_session_info",
                side_effect=RuntimeError("pid 12345 has no /dev/pts/* on fds 0/1/2"),
            ),
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "opencode",
                    "--pid",
                    "12345",
                    "--session-id",
                    "opencode-local",
                ]
            )

        self.assertEqual(result, 1)
        self.assertIn("has no /dev/pts", stderr.getvalue())

    def test_notify_only_loop_renotifies_when_inbox_changes_inside_debounce(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()
            inbox_path = broker_root / "opencode-local.inbox.json"
            inbox_path.write_text(
                json.dumps(
                    [
                        {
                            "from_alias": "codex",
                            "to_alias": "opencode-local",
                            "content": "first",
                        }
                    ]
                ),
                encoding="utf-8",
            )

            def replace_message(_seconds):
                inbox_path.write_text(
                    json.dumps(
                        [
                            {
                                "from_alias": "codex",
                                "to_alias": "opencode-local",
                                "content": "second",
                            }
                        ]
                    ),
                    encoding="utf-8",
                )

            with (
                mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
                mock.patch("c2c_deliver_inbox.time.sleep", side_effect=replace_message),
            ):
                result = c2c_deliver_inbox.run_loop(
                    session_id="opencode-local",
                    broker_root=broker_root,
                    client="opencode",
                    terminal_pid=33333,
                    pts="9",
                    dry_run=False,
                    timeout=0.1,
                    file_fallback=True,
                    notify_only=True,
                    submit_delay=None,
                    notify_debounce=30,
                    interval=0,
                    max_iterations=2,
                    watched_pid=None,
                )

            self.assertEqual(result["iterations"], 2)
            self.assertEqual(inject.call_count, 2)

    def test_notify_only_json_redacts_queued_message_bodies(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()
            inbox_path = broker_root / "codex-local.inbox.json"
            inbox_path.write_text(
                json.dumps(
                    [
                        {
                            "from_alias": "storm-echo",
                            "to_alias": "codex",
                            "content": "SECRET_NOTIFY_BODY",
                        }
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_session_info",
                    return_value=(33333, "9", None),
                ),
                mock.patch("c2c_deliver_inbox.c2c_poker.inject"),
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
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
                        "--notify-only",
                        "--json",
                    ]
                )

            self.assertEqual(result, 0)
            raw_output = stdout.getvalue()
            self.assertNotIn("SECRET_NOTIFY_BODY", raw_output)
            payload = json.loads(raw_output)
            self.assertEqual(payload["message_count"], 1)
            self.assertEqual(payload["messages"], [])
            self.assertTrue(payload["messages_redacted"])
            self.assertEqual(
                json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
                "SECRET_NOTIFY_BODY",
            )

    def test_deliver_once_xml_output_spools_and_clears_after_success(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()
            (broker_root / "codex-local.inbox.json").write_text(
                json.dumps(
                    [{"from_alias": "storm-echo", "to_alias": "codex", "content": "hello"}]
                ),
                encoding="utf-8",
            )
            read_fd, write_fd = os.pipe()
            try:
                result = c2c_deliver_inbox.deliver_once(
                    session_id="codex-local",
                    broker_root=broker_root,
                    client="codex",
                    terminal_pid=12345,
                    pts="9",
                    dry_run=False,
                    timeout=0.1,
                    file_fallback=True,
                    notify_only=False,
                    xml_output_fd=write_fd,
                )
                os.close(write_fd)
                payload = os.read(read_fd, 4096).decode("utf-8")
            finally:
                os.close(read_fd)

            self.assertEqual(result["delivered"], 1)
            self.assertIn('<message type="user">', payload)
            self.assertIn('<c2c event="message" from="storm-echo" alias="codex"', payload)
            spool_path = broker_root.parent / "codex-xml" / "codex-local.spool.json"
            self.assertEqual(json.loads(spool_path.read_text(encoding="utf-8")), [])
            self.assertEqual(
                json.loads((broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")),
                [],
            )

    def test_xml_message_payload_escapes_message_body(self):
        payload = c2c_deliver_inbox.xml_message_payload(
            {
                "from_alias": "storm-echo",
                "to_alias": "codex",
                "content": "5 < 6 & 7",
            }
        )

        self.assertIn("5 &lt; 6 &amp; 7", payload)
        self.assertNotIn("5 < 6 & 7</c2c>", payload)

    def test_deliver_once_xml_output_keeps_spool_on_write_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()
            (broker_root / "codex-local.inbox.json").write_text(
                json.dumps(
                    [{"from_alias": "storm-echo", "to_alias": "codex", "content": "hello"}]
                ),
                encoding="utf-8",
            )
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            os.close(write_fd)

            with self.assertRaises(OSError):
                c2c_deliver_inbox.deliver_once(
                    session_id="codex-local",
                    broker_root=broker_root,
                    client="codex",
                    terminal_pid=12345,
                    pts="9",
                    dry_run=False,
                    timeout=0.1,
                    file_fallback=True,
                    notify_only=False,
                    xml_output_fd=write_fd,
                )

            spool_path = broker_root.parent / "codex-xml" / "codex-local.spool.json"
            spooled = json.loads(spool_path.read_text(encoding="utf-8"))
            self.assertEqual(len(spooled), 1)
            self.assertEqual(spooled[0]["content"], "hello")

    def test_deliver_once_xml_output_preserves_inbox_when_spool_write_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()
            inbox_path = broker_root / "codex-local.inbox.json"
            message = {"from_alias": "storm-echo", "to_alias": "codex", "content": "hello"}
            inbox_path.write_text(json.dumps([message]), encoding="utf-8")

            with mock.patch.object(
                c2c_deliver_inbox.C2CSpool,
                "replace",
                side_effect=OSError("disk full"),
            ):
                with self.assertRaisesRegex(OSError, "disk full"):
                    c2c_deliver_inbox.deliver_once(
                        session_id="codex-local",
                        broker_root=broker_root,
                        client="codex",
                        terminal_pid=12345,
                        pts="9",
                        dry_run=False,
                        timeout=0.1,
                        file_fallback=True,
                        notify_only=False,
                        xml_output_fd=1,
                    )

            self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [message])


if __name__ == "__main__":
    unittest.main()
