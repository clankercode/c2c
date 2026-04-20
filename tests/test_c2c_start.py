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


class C2CStartUnitTests(unittest.TestCase):
    """Tests for c2c_start module."""

    def setUp(self):
        import c2c_start

        self.c2c_start = c2c_start
        self.temp_dir = tempfile.TemporaryDirectory()
        self.instances_dir = Path(self.temp_dir.name) / "instances"
        # Patch INSTANCES_DIR to point at temp dir.
        self._orig_instances_dir = c2c_start.INSTANCES_DIR
        c2c_start.INSTANCES_DIR = self.instances_dir

    def tearDown(self):
        self.c2c_start.INSTANCES_DIR = self._orig_instances_dir
        self.temp_dir.cleanup()

    def test_default_name_uses_client_and_hostname(self):
        name = self.c2c_start.default_name("claude")
        self.assertTrue(name.startswith("claude-"), name)

    def test_default_name_different_per_client(self):
        self.assertNotEqual(
            self.c2c_start.default_name("codex"),
            self.c2c_start.default_name("kimi"),
        )

    def test_invalid_client_rejected(self):
        broker_root = Path(self.temp_dir.name)
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_start(
                "nonexistent-client", "test-name", [], broker_root
            )
        self.assertEqual(rc, 1)
        self.assertIn("nonexistent-client", buf.getvalue())

    def test_invalid_client_rejected_json(self):
        broker_root = Path(self.temp_dir.name)
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.cmd_start(
                "nonexistent-client", "test-name", [], broker_root, json_out=True
            )
        self.assertEqual(rc, 1)
        result = json.loads(buf.getvalue())
        self.assertFalse(result["ok"])
        self.assertIn("error", result)

    def test_config_json_written_on_start(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        # Mock run_outer_loop so it doesn't actually launch anything.
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            rc = self.c2c_start.cmd_start("claude", "my-agent", ["--arg"], broker_root)
        self.assertEqual(rc, 0)
        cfg = self.c2c_start.load_instance_config("my-agent")
        self.assertIsNotNone(cfg)
        self.assertEqual(cfg["client"], "claude")
        self.assertEqual(cfg["name"], "my-agent")
        self.assertEqual(cfg["session_id"], "my-agent")
        self.assertEqual(cfg["alias"], "my-agent")
        self.assertEqual(cfg["extra_args"], ["--arg"])

    def test_config_json_includes_binary_override(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            rc = self.c2c_start.cmd_start(
                "claude", "my-agent", [], broker_root, binary_override="cc-zai"
            )
        self.assertEqual(rc, 0)
        cfg = self.c2c_start.load_instance_config("my-agent")
        self.assertEqual(cfg.get("binary_override"), "cc-zai")

    def test_custom_binary_override_used_by_run_outer_loop(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "run_outer_loop", return_value=0
        ) as mock_loop:
            self.c2c_start.cmd_start(
                "claude", "my-agent", [], broker_root, binary_override="cc-zai"
            )
        mock_loop.assert_called_once()
        self.assertEqual(mock_loop.call_args.kwargs.get("binary_override"), "cc-zai")

    def test_duplicate_name_rejected(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        # Write a fake pidfile with the current process PID (alive).
        inst_dir = self.instances_dir / "my-agent"
        inst_dir.mkdir(parents=True, exist_ok=True)
        (inst_dir / "outer.pid").write_text(str(os.getpid()))
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_start("claude", "my-agent", [], broker_root)
        self.assertEqual(rc, 1)
        self.assertIn("already running", buf.getvalue())

    def test_stop_nonexistent_returns_error(self):
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_stop("no-such-instance")
        self.assertEqual(rc, 1)

    def test_stop_nonexistent_json_returns_error(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.cmd_stop("no-such-instance", json_out=True)
        self.assertEqual(rc, 1)
        result = json.loads(buf.getvalue())
        self.assertFalse(result["ok"])

    def test_list_instances_empty(self):
        instances = self.c2c_start.list_instances()
        self.assertEqual(instances, [])

    def test_list_instances_returns_configured(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            self.c2c_start.cmd_start("codex", "test-codex", [], broker_root)
        instances = self.c2c_start.list_instances()
        self.assertEqual(len(instances), 1)
        self.assertEqual(instances[0]["name"], "test-codex")
        self.assertEqual(instances[0]["client"], "codex")

    def test_build_env_sets_required_vars(self):
        env = self.c2c_start.build_env("my-agent")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "my-agent")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "my-agent")
        self.assertIn("swarm-lounge", env.get("C2C_MCP_AUTO_JOIN_ROOMS", ""))
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertIn("C2C_MCP_BROKER_ROOT", env)

    def test_build_env_alias_override(self):
        env = self.c2c_start.build_env("my-agent", alias_override="storm-beacon")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "my-agent")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "storm-beacon")
        self.assertIn("swarm-lounge", env.get("C2C_MCP_AUTO_JOIN_ROOMS", ""))

    def test_kimi_launch_args_write_instance_mcp_config(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "kimi-proof", "kimi", ["--print"], broker_root
        )

        mcp_config = self.instances_dir / "kimi-proof" / "kimi-mcp.json"
        self.assertEqual(args[:2], ["--mcp-config-file", str(mcp_config)])
        self.assertEqual(args[2:], ["--print"])
        config = json.loads(mcp_config.read_text(encoding="utf-8"))
        env = config["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], str(broker_root))
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-proof")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-proof")
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")

    def test_kimi_launch_args_respect_alias_override(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "kimi-proof", "kimi", ["--print"], broker_root, alias_override="storm-beacon"
        )

        mcp_config = self.instances_dir / "kimi-proof" / "kimi-mcp.json"
        config = json.loads(mcp_config.read_text(encoding="utf-8"))
        env = config["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "storm-beacon")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-proof")

    def test_kimi_launch_args_respect_explicit_mcp_config(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "kimi-proof",
            "kimi",
            ["--mcp-config-file", "/tmp/custom.json", "--print"],
            broker_root,
        )

        self.assertEqual(args, ["--mcp-config-file", "/tmp/custom.json", "--print"])
        self.assertFalse((self.instances_dir / "kimi-proof" / "kimi-mcp.json").exists())

    def test_non_kimi_launch_args_unchanged(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "codex-proof", "codex", ["--approval-policy", "never"], broker_root
        )

        self.assertEqual(args, ["--approval-policy", "never"])

    def test_instances_cli_empty_json(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.main(["instances", "--json"])
        self.assertEqual(rc, 0)
        result = json.loads(buf.getvalue())
        self.assertEqual(result, [])

    def test_instances_cli_text_empty(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.main(["instances"])
        self.assertEqual(rc, 0)
        self.assertIn("No c2c instances", buf.getvalue())

    def test_start_cli_bin_flag_passed_to_cmd_start(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "cmd_start", return_value=0
        ) as mock_cmd:
            rc = self.c2c_start.main(
                [
                    "--broker-root",
                    str(broker_root),
                    "start",
                    "claude",
                    "-n",
                    "zai",
                    "--bin",
                    "cc-zai",
                    "--",
                    "--dangerously-skip-permissions",
                ]
            )
        self.assertEqual(rc, 0)
        mock_cmd.assert_called_once()
        args, kwargs = mock_cmd.call_args
        self.assertEqual(args, ("claude", "zai", ["--dangerously-skip-permissions"], broker_root))
        self.assertEqual(kwargs.get("binary_override"), "cc-zai")

    def test_start_cli_alias_flag_passed_to_cmd_start(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "cmd_start", return_value=0
        ) as mock_cmd:
            rc = self.c2c_start.main(
                [
                    "--broker-root",
                    str(broker_root),
                    "start",
                    "claude",
                    "-n",
                    "c2c-r2-b2",
                    "--alias",
                    "storm-beacon",
                ]
            )
        self.assertEqual(rc, 0)
        mock_cmd.assert_called_once()
        args, kwargs = mock_cmd.call_args
        self.assertEqual(args, ("claude", "c2c-r2-b2", [], broker_root))
        self.assertEqual(kwargs.get("alias_override"), "storm-beacon")


class C2CStartDeliverDaemonTests(unittest.TestCase):
    """Tests for _start_deliver_daemon client-specific command construction."""

    def setUp(self):
        import c2c_start
        self.c2c_start = c2c_start

    def test_deliver_daemon_uses_correct_client_flag_per_type(self):
        broker_root = Path("/tmp/broker")
        for client in ("claude", "codex", "opencode", "kimi", "crush"):
            with mock.patch("subprocess.Popen") as mock_popen:
                mock_popen.return_value.poll.return_value = None
                self.c2c_start._start_deliver_daemon("test-inst", client, broker_root, child_pid=12345)
            mock_popen.assert_called_once()
            cmd = mock_popen.call_args[0][0]
            self.assertIn("--client", cmd)
            client_idx = cmd.index("--client")
            self.assertEqual(cmd[client_idx + 1], client, f"wrong --client for {client}")
            self.assertIn("--session-id", cmd)
            sid_idx = cmd.index("--session-id")
            self.assertEqual(cmd[sid_idx + 1], "test-inst")
            self.assertIn(str(broker_root), cmd)
            self.assertIn("--pid", cmd)
            pid_idx = cmd.index("--pid")
            self.assertEqual(cmd[pid_idx + 1], "12345")

    def test_deliver_daemon_returns_none_when_script_missing(self):
        with mock.patch.object(self.c2c_start, "HERE", Path("/nonexistent")):
            result = self.c2c_start._start_deliver_daemon("x", "codex", Path("/tmp"))
        self.assertIsNone(result)

    def test_poker_starts_only_for_clients_that_need_it(self):
        for client, needs in (
            ("claude", True),
            ("codex", False),
            ("opencode", False),
            ("kimi", True),
            ("crush", False),
        ):
            with mock.patch("subprocess.Popen") as mock_popen:
                mock_popen.return_value.poll.return_value = None
                result = self.c2c_start._start_poker("test-inst", client, child_pid=12345)
            if needs:
                self.assertIsNotNone(result, f"{client} should start poker")
                mock_popen.assert_called_once()
                cmd = mock_popen.call_args[0][0]
                self.assertIn("--pid", cmd)
                pid_idx = cmd.index("--pid")
                self.assertEqual(cmd[pid_idx + 1], "12345")
            else:
                self.assertIsNone(result, f"{client} should not start poker")
                mock_popen.assert_not_called()


class C2CStartOuterLoopBehaviorTests(unittest.TestCase):
    """Tests for run_outer_loop edge cases: SIGINT and backoff."""

    def setUp(self):
        import c2c_start, signal
        self.c2c_start = c2c_start
        self.temp_dir = tempfile.TemporaryDirectory()
        self.instances_dir = Path(self.temp_dir.name) / "instances"
        self._orig_instances_dir = c2c_start.INSTANCES_DIR
        c2c_start.INSTANCES_DIR = self.instances_dir
        self._orig_sigchld = signal.getsignal(signal.SIGCHLD)
        # Prevent _preflight_pidfd_check from calling subprocess.run (uses real Popen)
        self._preflight_patcher = mock.patch.object(
            c2c_start, "_preflight_pidfd_check", return_value=(True, None)
        )
        self._preflight_patcher.start()
        # Prevent signal.signal calls from leaking SIGCHLD=SIG_IGN into the process
        self._signal_patcher = mock.patch("signal.signal")
        self._signal_patcher.start()

    def tearDown(self):
        import signal
        self._signal_patcher.stop()
        self._preflight_patcher.stop()
        self.c2c_start.INSTANCES_DIR = self._orig_instances_dir
        self.temp_dir.cleanup()
        signal.signal(signal.SIGCHLD, self._orig_sigchld)

    def test_run_outer_loop_prints_resume_command_on_exit(self):
        """After child exits, the outer loop prints a resume command."""
        import io
        from contextlib import redirect_stdout

        mock_child = mock.Mock()
        mock_child.poll.return_value = None
        mock_child.wait.return_value = 0

        buf = io.StringIO()
        with (
            mock.patch.object(self.c2c_start, "broker_root", return_value=Path("/tmp/broker")),
            mock.patch.object(self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0),
            mock.patch.object(self.c2c_start, "_start_deliver_daemon", return_value=None),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=None),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/binary"),
            mock.patch("time.monotonic", side_effect=[0, 5]),
            redirect_stdout(buf),
        ):
            rc = self.c2c_start.run_outer_loop(
                "my-instance", "claude", [], Path("/tmp/broker")
            )

        self.assertEqual(rc, 0)
        output = buf.getvalue()
        self.assertIn("c2c start claude -n my-instance", output)

    def test_run_outer_loop_ignores_sigchld_to_reap_sidecars(self):
        """SIGCHLD is ignored so dead deliver/poker processes are auto-reaped."""
        mock_child = mock.Mock()
        mock_child.wait.return_value = 0
        mock_deliver = mock.Mock()
        mock_poker = mock.Mock()

        with (
            mock.patch.object(
                self.c2c_start, "broker_root", return_value=Path("/tmp/broker")
            ),
            mock.patch.object(
                self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0
            ),
            mock.patch.object(
                self.c2c_start, "_start_deliver_daemon", return_value=mock_deliver
            ),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=mock_poker),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/binary"),
            mock.patch("time.monotonic", side_effect=[0, 5]),
            mock.patch("signal.signal") as mock_signal,
        ):
            rc = self.c2c_start.run_outer_loop(
                "my-instance", "claude", [], Path("/tmp/broker")
            )

        self.assertEqual(rc, 0)
        mock_signal.assert_any_call(
            self.c2c_start.signal.SIGCHLD, self.c2c_start.signal.SIG_IGN
        )

    def test_run_outer_loop_sigint_exits_with_130(self):
        """SIGINT terminates child and exits with code 130 (no loop)."""
        call_count = 0

        def fake_wait(timeout=None):
            nonlocal call_count
            if timeout == 2.0:
                return 0
            call_count += 1
            raise KeyboardInterrupt()

        mock_child = mock.Mock()
        mock_child.poll.return_value = None
        mock_child.wait.side_effect = fake_wait
        mock_child.terminate.return_value = None
        mock_child.kill.return_value = None

        with (
            mock.patch.object(self.c2c_start, "broker_root", return_value=Path("/tmp/broker")),
            mock.patch.object(self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0),
            mock.patch.object(self.c2c_start, "_start_deliver_daemon", return_value=None),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=None),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/binary"),
            mock.patch("time.sleep"),
            mock.patch("time.monotonic", side_effect=[0, 0.5, 0.5]),
        ):
            rc = self.c2c_start.run_outer_loop(
                "sigint-test", "codex", [], Path("/tmp/broker")
            )
        self.assertEqual(rc, 130)
        mock_child.terminate.assert_called_once()

    def test_run_outer_loop_double_sigint_exits_cleanly(self):
        """Two SIGINTs within window exit with code 130."""
        call_count = 0

        def fake_wait(timeout=None):
            nonlocal call_count
            if timeout == 2.0:
                return 0
            call_count += 1
            if call_count <= 2:
                raise KeyboardInterrupt()
            return 0

        mock_child = mock.Mock()
        mock_child.poll.return_value = None
        mock_child.wait.side_effect = fake_wait
        mock_child.terminate.return_value = None
        mock_child.kill.return_value = None

        with (
            mock.patch.object(self.c2c_start, "broker_root", return_value=Path("/tmp/broker")),
            mock.patch.object(self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0),
            mock.patch.object(self.c2c_start, "_start_deliver_daemon", return_value=None),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=None),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/binary"),
            mock.patch("time.sleep"),
            mock.patch("time.monotonic", side_effect=[0, 0.5, 0.5, 0.75]),
        ):
            rc = self.c2c_start.run_outer_loop(
                "sigint-test", "codex", [], Path("/tmp/broker")
            )
        self.assertEqual(rc, 130)

    def test_resume_command_includes_bin_flag(self):
        """Resume command includes --bin when a custom binary was used."""
        import io
        from contextlib import redirect_stdout

        mock_child = mock.Mock()
        mock_child.poll.return_value = None
        mock_child.wait.return_value = 0

        buf = io.StringIO()
        with (
            mock.patch.object(self.c2c_start, "broker_root", return_value=Path("/tmp/broker")),
            mock.patch.object(self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0),
            mock.patch.object(self.c2c_start, "_start_deliver_daemon", return_value=None),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=None),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/custom-binary"),
            mock.patch("time.monotonic", side_effect=[0, 5]),
            redirect_stdout(buf),
        ):
            rc = self.c2c_start.run_outer_loop(
                "my-instance", "claude", [], Path("/tmp/broker"),
                binary_override="/usr/local/bin/cc-zai",
            )

        self.assertEqual(rc, 0)
        output = buf.getvalue()
        self.assertIn("--bin /usr/local/bin/cc-zai", output)
        self.assertIn("c2c start claude -n my-instance", output)

    def test_resume_command_without_bin(self):
        """Resume command does not include --bin when no custom binary."""
        import io
        from contextlib import redirect_stdout

        mock_child = mock.Mock()
        mock_child.poll.return_value = None
        mock_child.wait.return_value = 0

        buf = io.StringIO()
        with (
            mock.patch.object(self.c2c_start, "broker_root", return_value=Path("/tmp/broker")),
            mock.patch.object(self.c2c_start.c2c_mcp, "cleanup_stale_tmp_fea_so", return_value=0),
            mock.patch.object(self.c2c_start, "_start_deliver_daemon", return_value=None),
            mock.patch.object(self.c2c_start, "_start_poker", return_value=None),
            mock.patch("subprocess.Popen", return_value=mock_child),
            mock.patch("shutil.which", return_value="/fake/binary"),
            mock.patch("time.monotonic", side_effect=[0, 5]),
            redirect_stdout(buf),
        ):
            rc = self.c2c_start.run_outer_loop(
                "my-instance", "claude", [], Path("/tmp/broker"),
            )

        self.assertEqual(rc, 0)
        output = buf.getvalue()
        self.assertNotIn("--bin", output)

    def test_cmd_start_resumes_existing_instance_config(self):
        """cmd_start loads saved config when resuming an existing instance."""
        inst_dir = self.instances_dir / "resume-test"
        inst_dir.mkdir(parents=True, exist_ok=True)
        config = {
            "name": "resume-test",
            "client": "claude",
            "session_id": "resume-test",
            "alias": "custom-alias",
            "binary_override": "/custom/binary",
            "extra_args": ["--dangerously-skip-permissions"],
            "broker_root": "/custom/broker",
            "created_at": 1000.0,
        }
        (inst_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")

        with (
            mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
            mock.patch("shutil.which", return_value="/fake/binary"),
        ):
            rc = self.c2c_start.cmd_start(
                "claude", "resume-test", [], Path("/tmp/default")
            )

        self.assertEqual(rc, 0)
        call_args, call_kwargs = mock_loop.call_args
        self.assertEqual(call_kwargs["binary_override"], "/custom/binary")
        self.assertEqual(call_kwargs["alias_override"], "custom-alias")
        self.assertEqual(call_args[2], ["--dangerously-skip-permissions"])

    def test_cmd_start_rejects_client_type_mismatch(self):
        """cmd_start refuses to resume if client type changed."""
        inst_dir = self.instances_dir / "type-mismatch"
        inst_dir.mkdir(parents=True, exist_ok=True)
        config = {
            "name": "type-mismatch",
            "client": "kimi",
            "session_id": "type-mismatch",
        }
        (inst_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")

        import io
        from contextlib import redirect_stderr
        buf = io.StringIO()
        with redirect_stderr(buf):
            rc = self.c2c_start.cmd_start(
                "claude", "type-mismatch", [], Path("/tmp/broker")
            )

        self.assertEqual(rc, 1)
        self.assertIn("kimi", buf.getvalue())

    def test_cmd_start_generates_stable_resume_session_id(self):
        """Resume session UUID is generated once and reused on subsequent starts."""
        with (
            mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
            mock.patch("shutil.which", return_value="/fake/binary"),
        ):
            self.c2c_start.cmd_start("claude", "uuid-test", [], Path("/tmp/broker"))
            first_call = mock_loop.call_args[1]
            first_uuid = first_call["resume_session_id"]
            self.assertIsNotNone(first_uuid)

            mock_loop.reset_mock()
            self.c2c_start.cmd_start("claude", "uuid-test", [], Path("/tmp/broker"))
            second_call = mock_loop.call_args[1]
            second_uuid = second_call["resume_session_id"]
            self.assertEqual(first_uuid, second_uuid)

    def test_cmd_start_session_id_override_is_passed_through(self):
        """CLI --session-id is passed through to run_outer_loop as resume_session_id."""
        with (
            mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
            mock.patch("shutil.which", return_value="/fake/binary"),
        ):
            self.c2c_start.cmd_start(
                "claude", "sid-test", [], Path("/tmp/broker"),
                session_id_override="550e8400-e29b-41d4-a716-446655440000",
            )
        call_kwargs = mock_loop.call_args[1]
        self.assertEqual(call_kwargs["resume_session_id"], "550e8400-e29b-41d4-a716-446655440000")

    def test_cmd_start_bad_session_id_rejected_before_state(self):
        """Invalid --session-id exits with an error before creating any state."""
        import uuid as _uuid
        # Confirm the input is actually invalid so this test doesn't false-pass.
        with self.assertRaises(ValueError):
            _uuid.UUID("not-a-uuid")

        inst_dir = self.instances_dir / "bad-sid"
        inst_dir.mkdir(parents=True, exist_ok=True)

        import io
        from contextlib import redirect_stderr
        buf = io.StringIO()
        with redirect_stderr(buf):
            rc = self.c2c_start.cmd_start(
                "claude", "bad-sid", [], Path("/tmp/broker"),
                session_id_override="not-a-uuid",
            )
        self.assertEqual(rc, 1)
        self.assertIn("550e8400-e29b-41d4-a716-446655440000", buf.getvalue())
        # State dir should NOT have been created (validation runs before mkdir).
        self.assertFalse((inst_dir / "config.json").exists())

    def test_cmd_start_session_id_override_beats_saved_config(self):
        """--session-id takes precedence over a saved resume_session_id."""
        inst_dir = self.instances_dir / "sid-override-test"
        inst_dir.mkdir(parents=True, exist_ok=True)
        config = {
            "name": "sid-override-test",
            "client": "claude",
            "session_id": "sid-override-test",
            "resume_session_id": "11111111-1111-1111-1111-111111111111",
        }
        (inst_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")

        with (
            mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0) as mock_loop,
            mock.patch("shutil.which", return_value="/fake/binary"),
        ):
            self.c2c_start.cmd_start(
                "claude", "sid-override-test", [], Path("/tmp/broker"),
                session_id_override="550e8400-e29b-41d4-a716-446655440000",
            )
        call_kwargs = mock_loop.call_args[1]
        # Override wins over saved value.
        self.assertEqual(call_kwargs["resume_session_id"], "550e8400-e29b-41d4-a716-446655440000")


class C2CStartConstantsTests(unittest.TestCase):
    """Task 1: constants, SUPPORTED_CLIENTS, and public helper API."""

    def test_client_configs_has_all_five_clients(self):
        from c2c_start import CLIENT_CONFIGS

        self.assertEqual(
            set(CLIENT_CONFIGS.keys()), {"claude", "codex", "opencode", "kimi", "crush"}
        )

    def test_supported_clients_matches_configs(self):
        from c2c_start import SUPPORTED_CLIENTS, CLIENT_CONFIGS

        self.assertEqual(SUPPORTED_CLIENTS, set(CLIENT_CONFIGS.keys()))

    def test_client_config_has_required_keys(self):
        from c2c_start import CLIENT_CONFIGS

        for client, cfg in CLIENT_CONFIGS.items():
            self.assertIn("binary", cfg, f"{client} missing binary")
            self.assertIn("deliver_client", cfg, f"{client} missing deliver_client")
            self.assertIn("needs_poker", cfg, f"{client} missing needs_poker")

    def test_deliver_client_values_match_deliver_inbox_choices(self):
        from c2c_start import CLIENT_CONFIGS

        valid_deliver_clients = {"claude", "codex", "opencode", "kimi", "crush"}
        for client, cfg in CLIENT_CONFIGS.items():
            self.assertIn(
                cfg["deliver_client"],
                valid_deliver_clients,
                f"{client} deliver_client must be a c2c_deliver_inbox --client value",
            )

    def test_constants_exist(self):
        import c2c_start

        self.assertEqual(c2c_start.DOUBLE_SIGINT_WINDOW_SECONDS, 2.0)

    def test_default_name_uses_hostname(self):
        from c2c_start import default_name

        with mock.patch("socket.gethostname", return_value="testhost"):
            self.assertEqual(default_name("claude"), "claude-testhost")
            self.assertEqual(default_name("codex"), "codex-testhost")

    def test_instances_dir_creates_on_access(self):
        from c2c_start import instances_dir

        with tempfile.TemporaryDirectory() as tmp:
            import c2c_start

            orig = c2c_start.INSTANCES_DIR
            try:
                c2c_start.INSTANCES_DIR = (
                    Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
                d = instances_dir()
                self.assertTrue(d.exists())
                self.assertEqual(
                    d, Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_instance_dir_path(self):
        from c2c_start import instance_dir

        with tempfile.TemporaryDirectory() as tmp:
            import c2c_start

            orig = c2c_start.INSTANCES_DIR
            try:
                c2c_start.INSTANCES_DIR = (
                    Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
                d = instance_dir("my-agent")
                self.assertEqual(
                    d, Path(tmp) / ".local" / "share" / "c2c" / "instances" / "my-agent"
                )
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_broker_root_uses_env_override(self):
        from c2c_start import broker_root

        with mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": "/custom/broker"}):
            self.assertEqual(broker_root(), Path("/custom/broker"))

    def test_read_pid_returns_int_or_none(self):
        from c2c_start import read_pid

        with tempfile.NamedTemporaryFile(mode="w", suffix=".pid", delete=False) as f:
            f.write("12345\n")
            f.flush()
            self.assertEqual(read_pid(Path(f.name)), 12345)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".pid", delete=False) as f:
            f.write("notanumber\n")
            f.flush()
            self.assertIsNone(read_pid(Path(f.name)))
        self.assertIsNone(read_pid(Path("/nonexistent/pidfile.pid")))

    def test_write_pid_creates_file(self):
        from c2c_start import write_pid

        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "sub" / "test.pid"
            write_pid(pidfile, 42)
            self.assertEqual(pidfile.read_text().strip(), "42")

    def test_pid_alive_live_process(self):
        from c2c_start import pid_alive

        self.assertTrue(pid_alive(os.getpid()))

    def test_pid_alive_dead_process(self):
        from c2c_start import pid_alive

        self.assertFalse(pid_alive(99999999))

    def test_cleanup_pidfiles_removes_stale(self):
        from c2c_start import cleanup_pidfiles, write_pid

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            write_pid(d / "alive.pid", os.getpid())
            write_pid(d / "dead.pid", 99999999)
            cleaned = cleanup_pidfiles(d)
            self.assertIn("dead.pid", cleaned)
            self.assertTrue((d / "alive.pid").exists())
            self.assertFalse((d / "dead.pid").exists())

    def test_cleanup_pidfiles_empty_dir(self):
        from c2c_start import cleanup_pidfiles

        self.assertEqual(cleanup_pidfiles(Path("/nonexistent/dir")), [])

    def test_write_and_load_config(self):
        from c2c_start import write_config, load_config, instance_dir
        import c2c_start

        orig = c2c_start.INSTANCES_DIR
        with tempfile.TemporaryDirectory() as tmp:
            c2c_start.INSTANCES_DIR = Path(tmp) / "instances"
            try:
                path = write_config("test-agent", "claude", ["--verbose"])
                self.assertTrue(path.exists())
                cfg = load_config("test-agent")
                self.assertEqual(cfg["client"], "claude")
                self.assertEqual(cfg["name"], "test-agent")
                self.assertEqual(cfg["extra_args"], ["--verbose"])
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_load_config_missing_raises(self):
        from c2c_start import load_config
        import c2c_start

        orig = c2c_start.INSTANCES_DIR
        with tempfile.TemporaryDirectory() as tmp:
            c2c_start.INSTANCES_DIR = Path(tmp) / "instances"
            try:
                with self.assertRaises(SystemExit):
                    load_config("nonexistent")
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_cleanup_fea_so(self):
        from c2c_start import cleanup_fea_so

        fake = Path("/tmp/libfea_inject.so")
        fake.write_text("test", encoding="utf-8")
        cleanup_fea_so()
        self.assertFalse(fake.exists())
        # Calling again is a no-op.
        cleanup_fea_so()

    def test_prepare_launch_args_includes_resume_flags_for_claude(self):
        """Claude gets --session-id and --resume when resume_session_id is set."""
        from c2c_start import prepare_launch_args

        args = prepare_launch_args(
            "test-inst", "claude", [], Path("/tmp/broker"),
            resume_session_id="test-uuid-1234",
        )
        self.assertIn("--session-id", args)
        self.assertIn("test-uuid-1234", args)
        self.assertIn("--resume", args)

    def test_prepare_launch_args_no_resume_when_session_id_none(self):
        """No resume flags when resume_session_id is None."""
        from c2c_start import prepare_launch_args

        args = prepare_launch_args(
            "test-inst", "claude", [], Path("/tmp/broker"),
            resume_session_id=None,
        )
        self.assertNotIn("--resume", args)
        self.assertNotIn("--session-id", args)


if __name__ == "__main__":
    unittest.main()
