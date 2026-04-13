"""Tests for the Kimi Wire bridge: WireState, formatting, C2CSpool, WireClient, and CLI."""
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

import c2c_kimi_wire_bridge as bridge


class WireStateTests(unittest.TestCase):
    def test_initial_state_not_active(self):
        state = bridge.WireState()
        self.assertFalse(state.turn_active)
        self.assertEqual(state.steer_inputs, [])

    def test_turn_begin_and_end_toggle_active_state(self):
        state = bridge.WireState()

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnBegin", "payload": {"user_input": "hi"}},
        })
        self.assertTrue(state.turn_active)

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnEnd", "payload": {}},
        })
        self.assertFalse(state.turn_active)

    def test_steer_input_marks_consumed(self):
        state = bridge.WireState()
        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "SteerInput", "payload": {"user_input": "wake"}},
        })
        self.assertEqual(state.steer_inputs, ["wake"])

    def test_non_event_messages_are_ignored(self):
        state = bridge.WireState()
        state.apply_message({"jsonrpc": "2.0", "id": "1", "result": {}})
        self.assertFalse(state.turn_active)


class FormattingTests(unittest.TestCase):
    def test_formats_c2c_envelope(self):
        msg = {
            "from_alias": "codex",
            "to_alias": "kimi-wire",
            "content": "hello",
        }
        text = bridge.format_c2c_envelope(msg)

        self.assertIn('<c2c event="message"', text)
        self.assertIn('from="codex"', text)
        self.assertIn('alias="kimi-wire"', text)
        self.assertIn('source="broker"', text)
        self.assertIn("hello", text)

    def test_formats_multiple_messages_as_one_prompt(self):
        prompt = bridge.format_prompt([
            {"from_alias": "a", "to_alias": "k", "content": "one"},
            {"from_alias": "b", "to_alias": "k", "content": "two"},
        ])

        self.assertIn("one", prompt)
        self.assertIn("two", prompt)
        self.assertIn("\n\n", prompt)

    def test_envelope_escapes_special_chars_in_alias(self):
        msg = {"from_alias": 'a"b', "to_alias": "kimi", "content": "x"}
        text = bridge.format_c2c_envelope(msg)
        self.assertNotIn('"a"b"', text)


class SpoolTests(unittest.TestCase):
    def test_spool_append_replace_and_clear(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool = bridge.C2CSpool(Path(tmp) / "kimi.spool.json")

            spool.append([{"content": "one"}])
            spool.append([{"content": "two"}])
            self.assertEqual([m["content"] for m in spool.read()], ["one", "two"])

            spool.replace([{"content": "three"}])
            self.assertEqual([m["content"] for m in spool.read()], ["three"])

            spool.clear()
            self.assertEqual(spool.read(), [])

    def test_spool_read_returns_empty_for_missing_file(self):
        spool = bridge.C2CSpool(Path("/tmp/nonexistent-c2c-spool-test.json"))
        self.assertEqual(spool.read(), [])

    def test_spool_creates_parent_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool = bridge.C2CSpool(Path(tmp) / "nested" / "dir" / "spool.json")
            spool.append([{"content": "x"}])
            self.assertEqual(spool.read()[0]["content"], "x")


class ConfigTests(unittest.TestCase):
    def test_build_kimi_mcp_config_has_explicit_c2c_env(self):
        cfg = bridge.build_kimi_mcp_config(
            broker_root=Path("/broker"),
            session_id="kimi-wire",
            alias="kimi-wire",
            mcp_script=Path("/repo/c2c_mcp.py"),
        )

        env = cfg["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], "/broker")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")

    def test_build_kimi_mcp_config_uses_python3_command(self):
        cfg = bridge.build_kimi_mcp_config(
            broker_root=Path("/b"),
            session_id="s",
            alias="s",
            mcp_script=Path("/repo/c2c_mcp.py"),
        )
        c2c_server = cfg["mcpServers"]["c2c"]
        self.assertEqual(c2c_server["command"], "python3")
        self.assertIn("/repo/c2c_mcp.py", c2c_server["args"])


class WireClientTests(unittest.TestCase):
    def test_initialize_writes_jsonrpc_request(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.initialize()

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "initialize")
        self.assertEqual(written["params"]["protocol_version"], "1.9")
        self.assertEqual(result["protocol_version"], "1.9")

    def test_prompt_writes_user_input(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"status":"finished"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.prompt("hello")

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "prompt")
        self.assertEqual(written["params"]["user_input"], "hello")
        self.assertEqual(result["status"], "finished")

    def test_client_skips_notifications_before_response(self):
        """Events arriving before the response are applied to state but don't block."""
        stdin = io.StringIO()
        notification = '{"jsonrpc":"2.0","method":"event","params":{"type":"TurnBegin","payload":{}}}\n'
        response = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        stdout = io.StringIO(notification + response)
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        client.initialize()

        self.assertTrue(client.state.turn_active)

    def test_client_raises_on_error_response(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","error":{"code":-1,"message":"fail"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        with self.assertRaises(RuntimeError):
            client.prompt("hello")


class CLITests(unittest.TestCase):
    def test_dry_run_outputs_launch_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, output = bridge.run_main_capture([
                "--session-id", "kimi-wire",
                "--alias", "kimi-wire",
                "--broker-root", str(Path(tmp) / "broker"),
                "--work-dir", tmp,
                "--dry-run",
                "--json",
            ])

        self.assertEqual(rc, 0)
        payload = json.loads(output)
        self.assertEqual(payload["session_id"], "kimi-wire")
        self.assertIn("--wire", payload["launch"])
        self.assertTrue(payload["dry_run"])

    def test_once_delivers_spooled_message_with_fake_wire(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            spool.append([{"from_alias": "codex", "to_alias": "kimi-wire", "content": "hello"}])
            stdin = io.StringIO()
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
                '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
            )

            result = bridge.deliver_once(
                wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                spool=spool,
                broker_root=broker_root,
                session_id="kimi-wire",
                timeout=1.0,
            )

        self.assertEqual(result["delivered"], 1)
        self.assertEqual(spool.read(), [])
        self.assertIn("hello", stdin.getvalue())

    def test_once_returns_zero_delivered_when_spool_and_inbox_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            stdin = io.StringIO()
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
            )

            result = bridge.deliver_once(
                wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                spool=spool,
                broker_root=broker_root,
                session_id="kimi-wire-empty",
                timeout=0.0,
            )

        self.assertEqual(result["delivered"], 0)
        self.assertTrue(result["ok"])

    def test_once_keeps_spool_intact_if_prompt_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            spool.append([{"from_alias": "a", "to_alias": "b", "content": "kept"}])
            stdin = io.StringIO()
            # initialize succeeds, prompt fails
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
                '{"jsonrpc":"2.0","id":"2","error":{"code":-32600,"message":"bad request"}}\n'
            )

            with self.assertRaises(RuntimeError):
                bridge.deliver_once(
                    wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                    spool=spool,
                    broker_root=broker_root,
                    session_id="kimi-wire-fail",
                    timeout=1.0,
                )

            # assertion must be inside the with-block before temp dir cleanup
            self.assertEqual(len(spool.read()), 1)
            self.assertEqual(spool.read()[0]["content"], "kept")


class RunOnceLiveTests(unittest.TestCase):
    """Tests for run_once_live() using a mocked subprocess.Popen."""

    def _make_mock_proc(self, *wire_responses: str) -> mock.MagicMock:
        """Build a mock Popen process with canned Wire JSON-RPC stdout lines."""
        proc = mock.MagicMock()
        proc.stdin = io.StringIO()
        proc.stdout = io.StringIO("".join(wire_responses))
        proc.wait.return_value = 0
        return proc

    def test_run_once_live_delivers_spooled_message(self):
        """run_once_live delivers a pre-spooled message and clears the spool."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        prompt_resp = '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
        proc = self._make_mock_proc(init_resp, prompt_resp)

        # run_once_live closes proc.stdin in its finally block; capture writes
        # to a side buffer so we can inspect them after the call returns.
        written_buf = io.StringIO()
        proc.stdin = mock.MagicMock()
        proc.stdin.write.side_effect = written_buf.write
        proc.stdin.flush.return_value = None

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool_path = Path(tmp) / "spool.json"
            spool = bridge.C2CSpool(spool_path)
            spool.append([{"from_alias": "codex", "to_alias": "kimi-wire", "content": "wire-test"}])

            with mock.patch("subprocess.Popen", return_value=proc):
                result = bridge.run_once_live(
                    session_id="kimi-wire",
                    alias="kimi-wire",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=spool_path,
                    timeout=0.0,
                )

            self.assertEqual(result["delivered"], 1)
            self.assertTrue(result["ok"])
            self.assertEqual(spool.read(), [])
            self.assertIn("wire-test", written_buf.getvalue())

    def test_run_once_live_launch_includes_wire_and_yolo(self):
        """Subprocess is launched with --wire and --yolo flags."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("subprocess.Popen", return_value=proc) as mock_popen:
                bridge.run_once_live(
                    session_id="s",
                    alias="s",
                    broker_root=Path(tmp) / "broker",
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        launch_cmd = mock_popen.call_args[0][0]
        self.assertIn("--wire", launch_cmd)
        self.assertIn("--yolo", launch_cmd)
        self.assertIn("--mcp-config-file", launch_cmd)
        self.assertIn("--work-dir", launch_cmd)

    def test_run_once_live_writes_valid_mcp_config_json(self):
        """A valid MCP config JSON file is written and passed to kimi."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("subprocess.Popen", return_value=proc) as mock_popen:
                bridge.run_once_live(
                    session_id="test-sid",
                    alias="test-alias",
                    broker_root=Path(tmp) / "broker",
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        launch_cmd = mock_popen.call_args[0][0]
        cfg_idx = launch_cmd.index("--mcp-config-file") + 1
        cfg_path = Path(launch_cmd[cfg_idx])
        # The temp config is deleted after the function returns — we can't read it
        # directly, but we can check the launch args contain a path that ends in .json
        self.assertTrue(str(cfg_path).endswith(".json"))

    def test_run_once_live_returns_zero_delivered_when_nothing_queued(self):
        """run_once_live returns delivered=0 when spool and inbox are empty."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            with mock.patch("subprocess.Popen", return_value=proc):
                result = bridge.run_once_live(
                    session_id="empty-session",
                    alias="empty-session",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        self.assertEqual(result["delivered"], 0)
        self.assertTrue(result["ok"])


class HasPendingMessagesTests(unittest.TestCase):
    """Tests for _has_pending_messages() — the cheap inbox pre-check."""

    def test_returns_true_when_spool_has_messages(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool_path = Path(tmp) / "spool.json"
            bridge.C2CSpool(spool_path).append([{"content": "x"}])
            result = bridge._has_pending_messages(Path(tmp) / "broker", "s", spool_path)
        self.assertTrue(result)

    def test_returns_true_when_inbox_file_has_messages(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            inbox = broker_root / "test-session.inbox.json"
            inbox.write_text(
                json.dumps([{"from_alias": "a", "to_alias": "b", "content": "hi"}]),
                encoding="utf-8",
            )
            result = bridge._has_pending_messages(broker_root, "test-session",
                                                   Path(tmp) / "spool.json")
        self.assertTrue(result)

    def test_returns_false_when_both_spool_and_inbox_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            result = bridge._has_pending_messages(broker_root, "empty-session",
                                                   Path(tmp) / "spool.json")
        self.assertFalse(result)


class RunLoopLiveTests(unittest.TestCase):
    """Tests for run_loop_live() — the persistent Wire delivery daemon."""

    def _make_mock_proc(self, *wire_responses: str) -> mock.MagicMock:
        proc = mock.MagicMock()
        buf = io.StringIO()
        proc.stdin = mock.MagicMock()
        proc.stdin.write.side_effect = buf.write
        proc.stdin.flush.return_value = None
        proc.stdout = io.StringIO("".join(wire_responses))
        proc.wait.return_value = 0
        return proc

    def test_loop_delivers_messages_across_multiple_iterations(self):
        """Delivers messages found in successive iterations."""
        init = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        prompt_ok = '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
        # Two iterations: first has a message, second is empty
        procs = [self._make_mock_proc(init, prompt_ok), self._make_mock_proc(init)]
        proc_iter = iter(procs)

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            spool_path = Path(tmp) / "spool.json"
            bridge.C2CSpool(spool_path).append([{"from_alias": "a", "content": "loop-msg"}])

            with mock.patch("subprocess.Popen", side_effect=lambda *a, **k: next(proc_iter)):
                result = bridge.run_loop_live(
                    session_id="kimi-wire",
                    alias="kimi-wire",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=spool_path,
                    timeout=0.0,
                    interval=0.0,
                    max_iterations=2,
                )

        self.assertEqual(result["iterations"], 2)
        self.assertEqual(result["total_delivered"], 1)
        self.assertEqual(result["errors"], 0)
        self.assertTrue(result["ok"])

    def test_loop_skips_wire_subprocess_when_inbox_empty(self):
        """Wire subprocess is NOT started when inbox is empty on every iteration."""
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()

            with mock.patch("subprocess.Popen") as mock_popen:
                result = bridge.run_loop_live(
                    session_id="kimi-wire-empty",
                    alias="kimi-wire-empty",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                    interval=0.0,
                    max_iterations=3,
                )

        mock_popen.assert_not_called()
        self.assertEqual(result["iterations"], 3)
        self.assertEqual(result["total_delivered"], 0)

    def test_loop_counts_errors_but_continues(self):
        """Delivery errors increment error count but do not abort the loop."""
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            spool_path = Path(tmp) / "spool.json"
            bridge.C2CSpool(spool_path).append([{"content": "will-fail"}])

            with mock.patch("subprocess.Popen", side_effect=OSError("kimi not found")):
                result = bridge.run_loop_live(
                    session_id="kimi-wire-err",
                    alias="kimi-wire-err",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=spool_path,
                    timeout=0.0,
                    interval=0.0,
                    max_iterations=2,
                )

        self.assertEqual(result["iterations"], 2)
        self.assertGreater(result["errors"], 0)
        self.assertFalse(result["ok"])

    def test_loop_backs_off_on_consecutive_errors(self):
        """Exponential backoff: consecutive errors increase sleep time."""
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            spool_path = Path(tmp) / "spool.json"
            bridge.C2CSpool(spool_path).append([{"content": "failing"}])
            sleep_calls = []

            with mock.patch("subprocess.Popen", side_effect=OSError("no kimi")):
                with mock.patch("c2c_kimi_wire_bridge.time.sleep",
                                side_effect=lambda s: sleep_calls.append(s)):
                    bridge.run_loop_live(
                        session_id="kimi-wire-backoff",
                        alias="kimi-wire-backoff",
                        broker_root=broker_root,
                        work_dir=Path(tmp),
                        command="kimi",
                        spool_path=spool_path,
                        timeout=0.0,
                        interval=1.0,
                        max_iterations=3,
                    )

        # First error: sleep = 1.0 * 2^1 = 2.0
        # Second error: sleep = 1.0 * 2^2 = 4.0
        # (third iteration exits — no sleep after last)
        self.assertEqual(len(sleep_calls), 2)
        self.assertAlmostEqual(sleep_calls[0], 2.0)
        self.assertAlmostEqual(sleep_calls[1], 4.0)

    def test_loop_resets_backoff_after_success(self):
        """Error streak resets to 0 after a successful delivery."""
        init = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        prompt_ok = '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
        # iter 1: error; iter 2: success; iter 3: empty (no subprocess)
        call_count = [0]

        def popen_factory(*args, **kwargs):
            call_count[0] += 1
            if call_count[0] == 1:
                raise OSError("first call fails")
            proc = mock.MagicMock()
            buf = io.StringIO()
            proc.stdin = mock.MagicMock()
            proc.stdin.write.side_effect = buf.write
            proc.stdin.flush.return_value = None
            proc.stdout = io.StringIO(init + prompt_ok)
            proc.wait.return_value = 0
            return proc

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            spool_path = Path(tmp) / "spool.json"
            bridge.C2CSpool(spool_path).append([{"content": "recover"}])
            sleep_calls = []

            with mock.patch("subprocess.Popen", side_effect=popen_factory):
                with mock.patch("c2c_kimi_wire_bridge.time.sleep",
                                side_effect=lambda s: sleep_calls.append(s)):
                    result = bridge.run_loop_live(
                        session_id="kimi-wire-recover",
                        alias="kimi-wire-recover",
                        broker_root=broker_root,
                        work_dir=Path(tmp),
                        command="kimi",
                        spool_path=spool_path,
                        timeout=0.0,
                        interval=1.0,
                        max_iterations=3,
                    )

        # After error: sleep = 1 * 2^1 = 2.0; after success: streak reset → sleep = 1.0
        self.assertEqual(result["errors"], 1)
        self.assertEqual(result["total_delivered"], 1)
        self.assertEqual(sleep_calls[0], 2.0)   # backoff after error
        self.assertAlmostEqual(sleep_calls[1], 1.0)  # normal after success

    def test_loop_cli_flag_runs_loop_mode(self):
        """--loop flag activates loop mode in the CLI."""
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()

            with mock.patch("subprocess.Popen") as mock_popen:
                rc, output = bridge.run_main_capture([
                    "--session-id", "kimi-wire-loop",
                    "--broker-root", str(broker_root),
                    "--work-dir", tmp,
                    "--loop",
                    "--interval", "0",
                    "--max-iterations", "1",
                    "--json",
                ])

        self.assertEqual(rc, 0)
        payload = json.loads(output)
        self.assertEqual(payload["iterations"], 1)
        mock_popen.assert_not_called()  # empty inbox → no subprocess

    def test_once_and_loop_are_mutually_exclusive(self):
        """--once and --loop together should exit with an argparse error (code 2)."""
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            with self.assertRaises(SystemExit) as ctx:
                bridge.run_main([
                    "--session-id", "kimi-wire-excl",
                    "--broker-root", str(broker_root),
                    "--once",
                    "--loop",
                ])
        self.assertEqual(ctx.exception.code, 2)


class DaemonManagementTests(unittest.TestCase):
    """Tests for start_daemon(), pidfile writing, and --daemon CLI flag."""

    def test_start_daemon_returns_already_running_when_pidfile_live(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "wire.pid"
            log_path = Path(tmp) / "wire.log"
            pidfile.write_text(f"{os.getpid()}\n", encoding="utf-8")

            result = bridge.start_daemon(
                child_argv=["--session-id", "kimi-wire-test", "--loop"],
                pidfile=pidfile,
                log_path=log_path,
                wait_timeout=0.5,
            )

        self.assertTrue(result["ok"])
        self.assertTrue(result["already_running"])
        self.assertEqual(result["pid"], os.getpid())

    def test_start_daemon_spawns_child_and_waits_for_pidfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "wire.pid"
            log_path = Path(tmp) / "wire.log"
            proc = mock.Mock(pid=9191)
            proc.poll.return_value = None

            def write_pidfile(_seconds):
                pidfile.write_text("9191\n", encoding="utf-8")

            with (
                mock.patch("c2c_kimi_wire_bridge.subprocess.Popen", return_value=proc) as popen,
                mock.patch("c2c_kimi_wire_bridge.time.sleep", side_effect=write_pidfile),
            ):
                result = bridge.start_daemon(
                    child_argv=["--session-id", "kimi-wire-test", "--loop"],
                    pidfile=pidfile,
                    log_path=log_path,
                    wait_timeout=1.0,
                )

        self.assertTrue(result["ok"])
        self.assertFalse(result["already_running"])
        self.assertEqual(result["pid"], 9191)
        command = popen.call_args.args[0]
        self.assertIn("--loop", command)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_start_daemon_fails_when_child_exits_before_pidfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "wire.pid"
            log_path = Path(tmp) / "wire.log"
            proc = mock.Mock(pid=9292)
            proc.poll.return_value = 1  # already exited

            with (
                mock.patch("c2c_kimi_wire_bridge.subprocess.Popen", return_value=proc),
                mock.patch("c2c_kimi_wire_bridge.time.sleep"),
            ):
                result = bridge.start_daemon(
                    child_argv=["--session-id", "kimi-wire-test", "--loop"],
                    pidfile=pidfile,
                    log_path=log_path,
                    wait_timeout=0.5,
                )

        self.assertFalse(result["ok"])
        self.assertIn("error", result)

    def test_loop_writes_pidfile_before_iterating(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            pidfile = Path(tmp) / "wire.pid"

            with (
                mock.patch(
                    "c2c_kimi_wire_bridge._has_pending_messages",
                    return_value=False,
                ),
                mock.patch("c2c_kimi_wire_bridge.time.sleep"),
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                rc = bridge.run_main([
                    "--session-id", "kimi-wire-test",
                    "--broker-root", str(broker_root),
                    "--loop",
                    "--max-iterations", "1",
                    "--pidfile", str(pidfile),
                ])

            self.assertEqual(rc, 0)
            self.assertTrue(pidfile.exists())
            self.assertRegex(pidfile.read_text(encoding="utf-8"), r"^\d+\n$")

    def test_daemon_flag_requires_loop(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            pidfile = Path(tmp) / "wire.pid"
            with self.assertRaises(SystemExit) as ctx:
                bridge.run_main([
                    "--session-id", "kimi-wire-test",
                    "--broker-root", str(broker_root),
                    "--daemon",
                    "--pidfile", str(pidfile),
                ])
        self.assertEqual(ctx.exception.code, 2)

    def test_daemon_flag_requires_pidfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            with self.assertRaises(SystemExit) as ctx:
                bridge.run_main([
                    "--session-id", "kimi-wire-test",
                    "--broker-root", str(broker_root),
                    "--daemon",
                    "--loop",
                ])
        self.assertEqual(ctx.exception.code, 2)

    def test_daemon_flag_spawns_daemon_and_returns(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            pidfile = Path(tmp) / "wire.pid"

            with (
                mock.patch(
                    "c2c_kimi_wire_bridge.start_daemon",
                    return_value={
                        "ok": True,
                        "daemon": True,
                        "already_running": False,
                        "pid": 7878,
                    },
                ) as start_daemon,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                rc = bridge.run_main([
                    "--session-id", "kimi-wire-test",
                    "--broker-root", str(broker_root),
                    "--loop",
                    "--daemon",
                    "--pidfile", str(pidfile),
                ])

        self.assertEqual(rc, 0)
        start_daemon.assert_called_once()
        call_kwargs = start_daemon.call_args.kwargs
        self.assertEqual(call_kwargs["pidfile"], pidfile)

    def test_strip_daemon_args_removes_daemon_and_log_flags(self):
        argv = [
            "--session-id", "kimi-wire-test",
            "--loop",
            "--daemon",
            "--daemon-log", "/tmp/wire.log",
            "--daemon-timeout", "10",
            "--pidfile", "/tmp/wire.pid",
        ]
        stripped = bridge._strip_daemon_args(argv)
        self.assertNotIn("--daemon", stripped)
        self.assertNotIn("--daemon-log", stripped)
        self.assertNotIn("/tmp/wire.log", stripped)
        self.assertNotIn("--daemon-timeout", stripped)
        self.assertNotIn("10", stripped)
        self.assertIn("--session-id", stripped)
        self.assertIn("--loop", stripped)
        self.assertIn("--pidfile", stripped)


if __name__ == "__main__":
    unittest.main()
