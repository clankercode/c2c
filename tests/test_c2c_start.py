import io
import json
import os
import subprocess
import sys
import tempfile
import time
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

    def test_supported_clients_include_codex_headless(self):
        self.assertIn("codex-headless", self.c2c_start.SUPPORTED_CLIENTS)

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

    def test_codex_launch_args_use_xml_input_fd_when_supported(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "codex-proof",
            "codex",
            ["--approval-policy", "never"],
            broker_root,
            codex_xml_input_fd=3,
        )

        self.assertEqual(args, ["--xml-input-fd", "3", "--approval-policy", "never"])

    def test_start_deliver_daemon_uses_xml_fd_without_notify_only(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch("c2c_start.subprocess.Popen") as popen:
            self.c2c_start._start_deliver_daemon(
                "codex-proof",
                "codex",
                broker_root,
                12345,
                xml_output_fd=7,
            )

        cmd = popen.call_args.args[0]
        self.assertIn("--xml-output-fd", cmd)
        self.assertNotIn("--notify-only", cmd)

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

    def test_prepare_launch_args_opencode_uses_session_file_over_uuid(self):
        """prepare_launch_args passes --session <ses_*> from opencode-session.txt.

        The plugin writes opencode-session.txt on first session.created. On next
        `c2c start opencode -n <name>`, prepare_launch_args must prefer the ses_*
        ID from the file over any UUID resume_session_id (which opencode rejects).
        """
        from c2c_start import prepare_launch_args

        inst_name = "oc-resume-e2e"
        inst_dir = self.instances_dir / inst_name
        inst_dir.mkdir(parents=True)

        ses_id = "ses_deadbeef1234"
        (inst_dir / "opencode-session.txt").write_text(ses_id + "\n")

        # Pass a UUID as resume_session_id — file should win
        with mock.patch("c2c_start.instance_dir", return_value=inst_dir):
            args = prepare_launch_args(
                inst_name, "opencode", [], self.instances_dir.parent / "broker",
                resume_session_id="550e8400-e29b-41d4-a716-446655440000",
                is_resume=True,
            )

        self.assertIn("--session", args, "--session flag must be present")
        idx = args.index("--session")
        self.assertEqual(args[idx + 1], ses_id,
                         "ses_* from opencode-session.txt must win over UUID")


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


class C2CStartCodexHeadlessTests(unittest.TestCase):
    """Task 2: codex-headless launcher entry and opaque resume ids."""

    def setUp(self):
        import c2c_start

        self.c2c_start = c2c_start
        self.temp_dir = tempfile.TemporaryDirectory()
        self.instances_dir = Path(self.temp_dir.name) / "instances"
        self._orig_instances_dir = c2c_start.INSTANCES_DIR
        c2c_start.INSTANCES_DIR = self.instances_dir

    def tearDown(self):
        self.c2c_start.INSTANCES_DIR = self._orig_instances_dir
        self.temp_dir.cleanup()

    def test_cmd_start_initial_headless_config_uses_empty_resume_id(self):
        """First start of codex-headless stores empty resume_session_id."""
        broker_root = Path(self.temp_dir.name) / "broker"
        with (
            mock.patch.object(
                self.c2c_start, "bridge_supports_thread_id_fd", return_value=True
            ),
            mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0),
        ):
            rc = self.c2c_start.cmd_start(
                "codex-headless", "headless-proof", [], broker_root
            )
        self.assertEqual(rc, 0)
        cfg = self.c2c_start.load_instance_config("headless-proof")
        self.assertEqual(cfg["resume_session_id"], "")

    def test_codex_headless_launch_args_force_bridge_flags(self):
        """codex-headless prepare_launch_args includes bridge flags."""
        broker_root = Path(self.temp_dir.name) / "broker"
        args = self.c2c_start.prepare_launch_args(
            "headless-proof",
            "codex-headless",
            ["--model", "gpt-5"],
            broker_root,
            resume_session_id="thread-abc",
        )
        self.assertEqual(
            args,
            [
                "--stdin-format", "xml",
                "--codex-bin", "codex",
                "--approval-policy", "never",
                "--thread-id", "thread-abc",
                "--model", "gpt-5",
            ],
        )

    def test_codex_headless_session_id_override_accepts_opaque_thread_id(self):
        """codex-headless accepts opaque thread id via --session-id."""
        broker_root = Path(self.temp_dir.name) / "broker"
        with (
            mock.patch.object(
                self.c2c_start, "bridge_supports_thread_id_fd", return_value=True
            ),
            mock.patch.object(
                self.c2c_start, "run_outer_loop", return_value=0
            ) as mock_loop,
        ):
            rc = self.c2c_start.cmd_start(
                "codex-headless",
                "headless-proof",
                [],
                broker_root,
                session_id_override="thread-opaque-123",
            )
        self.assertEqual(rc, 0)
        self.assertEqual(
            mock_loop.call_args.kwargs["resume_session_id"], "thread-opaque-123"
        )

    def test_saved_headless_resume_id_is_not_regenerated_as_uuid(self):
        """Saved opaque resume id is preserved, not replaced with a UUID."""
        inst_dir = self.instances_dir / "headless-proof"
        inst_dir.mkdir(parents=True, exist_ok=True)
        (inst_dir / "config.json").write_text(
            json.dumps({
                "name": "headless-proof",
                "client": "codex-headless",
                "session_id": "headless-proof",
                "resume_session_id": "thread-still-opaque",
                "alias": "headless-proof",
                "extra_args": [],
                "created_at": 0,
                "broker_root": str(Path(self.temp_dir.name) / "broker"),
                "auto_join_rooms": "swarm-lounge",
            }),
            encoding="utf-8",
        )
        with (
            mock.patch.object(
                self.c2c_start, "bridge_supports_thread_id_fd", return_value=True
            ),
            mock.patch.object(
                self.c2c_start, "run_outer_loop", return_value=0
            ) as mock_loop,
        ):
            rc = self.c2c_start.cmd_start(
                "codex-headless",
                "headless-proof",
                [],
                Path(self.temp_dir.name) / "broker",
            )
        self.assertEqual(rc, 0)
        self.assertEqual(
            mock_loop.call_args.kwargs["resume_session_id"], "thread-still-opaque"
        )

    def test_codex_headless_requires_thread_id_handoff_capability(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "bridge_supports_thread_id_fd", return_value=False
        ):
            buf = io.StringIO()
            with mock.patch("sys.stderr", buf):
                rc = self.c2c_start.cmd_start(
                    "codex-headless", "headless-proof", [], broker_root
                )
        self.assertEqual(rc, 1)
        self.assertIn("--thread-id-fd", buf.getvalue())

    def test_codex_headless_start_does_not_block_waiting_for_first_thread_id(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with (
            mock.patch.object(
                self.c2c_start, "bridge_supports_thread_id_fd", return_value=True
            ),
            mock.patch.object(
                self.c2c_start, "run_outer_loop", return_value=0
            ) as mock_loop,
        ):
            rc = self.c2c_start.cmd_start(
                "codex-headless", "headless-proof", [], broker_root
            )
        self.assertEqual(rc, 0)
        self.assertIsNone(mock_loop.call_args.kwargs["resume_session_id"])

    def test_persist_headless_thread_id_updates_config(self):
        cfg = {
            "name": "headless-proof",
            "client": "codex-headless",
            "session_id": "headless-proof",
            "resume_session_id": "",
            "alias": "headless-proof",
            "extra_args": [],
            "created_at": 0,
            "broker_root": str(Path(self.temp_dir.name) / "broker"),
            "auto_join_rooms": "swarm-lounge",
        }
        self.c2c_start.save_instance_config("headless-proof", cfg)
        self.c2c_start.persist_headless_thread_id("headless-proof", "thread-new")
        saved = self.c2c_start.load_instance_config("headless-proof")
        self.assertEqual(saved["resume_session_id"], "thread-new")


class C2CStartConstantsTests(unittest.TestCase):
    """Task 1: constants, SUPPORTED_CLIENTS, and public helper API."""

    def test_client_configs_has_all_six_clients(self):
        from c2c_start import CLIENT_CONFIGS

        self.assertEqual(
            set(CLIENT_CONFIGS.keys()),
            {"claude", "codex", "opencode", "kimi", "crush", "codex-headless"},
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

    def test_prepare_launch_args_opencode_passes_session_flag_for_ses_id(self):
        """OpenCode gets --session <ses_*> when resume_session_id starts with 'ses'."""
        from c2c_start import prepare_launch_args

        args = prepare_launch_args(
            "oc-test", "opencode", [], Path("/tmp/broker"),
            resume_session_id="ses_abc123xyz",
        )
        self.assertIn("--session", args)
        idx = args.index("--session")
        self.assertEqual(args[idx + 1], "ses_abc123xyz")

    def test_prepare_launch_args_opencode_no_session_for_uuid(self):
        """OpenCode does NOT get --session when resume_session_id is a UUID (not ses_*)."""
        from c2c_start import prepare_launch_args

        args = prepare_launch_args(
            "oc-test", "opencode", [], Path("/tmp/broker"),
            resume_session_id="550e8400-e29b-41d4-a716-446655440000",
        )
        self.assertNotIn("--session", args)

CLI_EXE = Path(__file__).resolve().parents[1] / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"
_CLI_BUILT = CLI_EXE.exists()
_CLI_SKIP = unittest.skipUnless(_CLI_BUILT, "OCaml CLI binary not built — run `just build-cli`")

CLI_TIMEOUT = 10.0  # seconds; exit-109 path should complete in <3s


@_CLI_SKIP
class C2CStartExit109RegressionTests(unittest.TestCase):
    """Regression: `c2c start opencode --bin <stub>` propagates exit 109 with diagnostic.

    If opencode exits 109 (SQLite DB lock contention), c2c start must:
      1. Propagate exit code 109 to the caller.
      2. Print the diagnostic hint to stderr.
      3. Complete within CLI_TIMEOUT seconds (no hang).

    This class locks down bd41f9e so the behaviour can't quietly regress.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        # Instance state goes into the temp dir (C2C_INSTANCES_DIR) so tests
        # don't leave stale entries in ~/.local/share/c2c/instances/.
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir(parents=True)
        # Stub opencode binary named "opencode" so find_binary() resolves it.
        # Prepend self.tmp_path to PATH so it wins over any real opencode.
        self.stub = self.tmp_path / "opencode"
        self.stub.write_text("#!/bin/sh\nexit 109\n")
        self.stub.chmod(0o755)
        import uuid
        self._run_id = uuid.uuid4().hex[:8]

    def tearDown(self):
        self.tmp.cleanup()

    def _run_c2c_start(self, name: str) -> tuple[int, str, str]:
        """Run `c2c start opencode --bin <stub>` and return (returncode, stdout, stderr)."""
        from tests.conftest import spawn_tracked, clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            # Prepend tmp dir so stub "opencode" shadows any real binary.
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            # Redirect instance state to temp dir so no stale entries accumulate
            # in ~/.local/share/c2c/instances/ after tests run.
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            # Prevent git rev-parse from finding the real repo so
            # refresh_opencode_identity doesn't patch .opencode/opencode.json.
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        try:
            stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"c2c start timed out after {CLI_TIMEOUT}s (stdout={stdout!r})")
        return proc.returncode, stdout, stderr

    def test_exit109_propagated(self):
        """c2c start propagates exit code 109 from opencode."""
        rc, _out, _err = self._run_c2c_start(f"t109-prop-{self._run_id}")
        self.assertEqual(rc, 109, f"expected exit 109, got {rc}")

    def test_exit109_prints_hint(self):
        """c2c start emits a diagnostic hint on stderr when opencode exits 109."""
        _rc, _out, stderr = self._run_c2c_start(f"t109-hint-{self._run_id}")
        self.assertIn("109", stderr, f"hint missing in stderr: {stderr!r}")
        self.assertIn("lock", stderr.lower(), f"lock hint missing in stderr: {stderr!r}")

    def test_exit109_completes_fast(self):
        """c2c start does not hang when opencode exits 109 — must complete in <CLI_TIMEOUT."""
        start = time.monotonic()
        self._run_c2c_start(f"t109-fast-{self._run_id}")
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, CLI_TIMEOUT, f"took {elapsed:.1f}s — possible hang")

    def test_exit109_logs_death_record(self):
        """c2c start records a death entry in deaths.jsonl on exit 109."""
        name = f"t109-death-{self._run_id}"
        self._run_c2c_start(name)
        # deaths.jsonl lives at <broker_root>/deaths.jsonl (see deaths_jsonl_path in c2c_start.ml)
        deaths_file = self.broker_root / "deaths.jsonl"
        self.assertTrue(deaths_file.exists(), f"deaths.jsonl not found at {deaths_file}")
        entries = [json.loads(l) for l in deaths_file.read_text().splitlines() if l.strip()]
        self.assertTrue(any(e.get("exit_code") == 109 for e in entries),
                        f"no exit_code=109 in deaths.jsonl: {entries}")


@_CLI_SKIP
class C2CGitShimRegressionTests(unittest.TestCase):
    """Regression: managed-session git shim must not recurse back into c2c git."""

    CLI_TIMEOUT = 3.0

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.shim_dir = self.tmp_path / "shim"
        self.real_dir = self.tmp_path / "real"
        self.log_path = self.tmp_path / "real-git.log"
        self.shim_dir.mkdir()
        self.real_dir.mkdir()

        self.real_git = self.real_dir / "git"
        self.real_git.write_text(
            "#!/bin/sh\n"
            f"printf 'argv:%s\\n' \"$*\" > {self.log_path}\n"
            f"printf 'author_name:%s\\n' \"${{GIT_AUTHOR_NAME-}}\" >> {self.log_path}\n"
            f"printf 'author_email:%s\\n' \"${{GIT_AUTHOR_EMAIL-}}\" >> {self.log_path}\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self.real_git.chmod(0o755)

        self.shim_git = self.shim_dir / "git"
        self.shim_git.write_text(
            "#!/bin/sh\n"
            f"exec {CLI_EXE} git -- \"$@\"\n",
            encoding="utf-8",
        )
        self.shim_git.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _run_git(self, *git_args: str) -> subprocess.CompletedProcess[str]:
        from tests.conftest import clean_c2c_start_env

        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": f"{self.shim_dir}:{self.real_dir}:{base_env.get('PATH', '')}",
            "C2C_GIT_SHIM_DIR": str(self.shim_dir),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "shim-tester",
        }
        return subprocess.run(
            [str(CLI_EXE), "git", *git_args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=self.tmp_path,
            timeout=self.CLI_TIMEOUT,
        )

    def _log_lines(self) -> list[str]:
        return self.log_path.read_text(encoding="utf-8").splitlines()

    def test_git_subcommand_skips_managed_shim_and_reaches_real_git(self):
        result = self._run_git("--", "status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.log_path.exists(), "real git was never reached")
        self.assertEqual(
            self._log_lines(),
            [
                "argv:status",
                "author_name:shim-tester",
                "author_email:shim-tester@c2c.im",
            ],
        )

    def test_git_subcommand_respects_explicit_author_without_env_injection(self):
        result = self._run_git("--", "commit", "--author=Explicit <explicit@example.com>", "-m", "msg")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.log_path.exists(), "real git was never reached")
        self.assertEqual(
            self._log_lines(),
            [
                "argv:commit --author=Explicit <explicit@example.com> -m msg",
                "author_name:",
                "author_email:",
            ],
        )


@_CLI_SKIP
class C2CStartOpencodeSessionPreflightTests(unittest.TestCase):
    """Pre-flight: c2c start opencode -s ses_* must verify the session exists.

    When -s ses_<id> is provided, c2c start calls `opencode session list --format json`
    and exits 1 with an error message if the session is not found — instead of
    silently hanging after opencode creates a new session for the unknown ID.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir(parents=True)
        import uuid
        self._run_id = uuid.uuid4().hex[:8]

    def tearDown(self):
        self.tmp.cleanup()

    def _make_opencode_stub(self, session_ids: list) -> Path:
        """Create a stub opencode binary that returns the given session IDs."""
        import json as _json
        sessions_json = _json.dumps([
            {"id": sid, "title": f"Session {sid}", "updated": 1000000000000,
             "created": 1000000000000, "projectId": "proj123", "directory": "/tmp"}
            for sid in session_ids
        ])
        stub = self.tmp_path / "opencode"
        stub.write_text(
            "#!/bin/sh\n"
            # Match: opencode session list --format json
            'if [ "$1" = "session" ] && [ "$2" = "list" ]; then\n'
            f"  echo '{sessions_json}'\n"
            "  exit 0\n"
            "fi\n"
            # Any other invocation: simulate a fast exit so the test doesn't hang
            "exit 1\n"
        )
        stub.chmod(0o755)
        return stub

    def _run_start_with_session(self, ses_id: str, session_ids: list) -> tuple[int, str, str]:
        stub = self._make_opencode_stub(session_ids)
        name = f"preflight-{self._run_id}"
        from tests.conftest import spawn_tracked, clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", name, "-s", ses_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        try:
            stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"c2c start hung waiting for opencode session preflight (ses={ses_id!r})")
        return proc.returncode, stdout, stderr

    def test_missing_session_exits_with_error(self):
        """c2c start exits 1 with a clear message when the ses_* ID is not in session list."""
        rc, _out, stderr = self._run_start_with_session(
            "ses_nonexistent999", session_ids=["ses_abc123", "ses_def456"]
        )
        self.assertEqual(rc, 1, f"expected exit 1, got {rc}; stderr={stderr!r}")
        self.assertIn("ses_nonexistent999", stderr,
                      f"error must mention the bad session ID; stderr={stderr!r}")
        self.assertIn("not found", stderr.lower(),
                      f"error must say 'not found'; stderr={stderr!r}")

    def test_missing_session_suggests_list_command(self):
        """Error message suggests 'opencode session list' to the user."""
        _rc, _out, stderr = self._run_start_with_session(
            "ses_missing", session_ids=[]
        )
        self.assertIn("opencode session list", stderr,
                      f"hint missing from stderr: {stderr!r}")

    def test_valid_session_passes_preflight(self):
        """c2c start passes preflight (and proceeds to launch) when session exists."""
        VALID = "ses_good000"
        # The stub opencode will exit 1 on the actual launch (not session list),
        # so the process exits non-zero — but not exit 1 from preflight.
        # The key is it should NOT have the "not found" error in stderr.
        _rc, _out, stderr = self._run_start_with_session(
            VALID, session_ids=[VALID]
        )
        self.assertNotIn("not found", stderr.lower(),
                         f"preflight should not have failed; stderr={stderr!r}")


@_CLI_SKIP
class C2CStartRegistryCleanupRegressionTests(unittest.TestCase):
    """Regression coverage for clean-exit registry cleanup in OCaml c2c start."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir(parents=True)
        self.stub = self.tmp_path / "opencode"
        self.stub.write_text("#!/bin/sh\nexit 0\n")
        self.stub.chmod(0o755)
        self.name = "clean-exit-registry"
        registry = [
            {
                "session_id": self.name,
                "alias": self.name,
                "pid": 4242,
                "pid_start_time": 9999,
                "registered_at": 1234.5,
            },
            {
                "session_id": "peer",
                "alias": "peer",
                "pid": 5252,
                "pid_start_time": 8888,
            },
        ]
        registry_path = self.broker_root / "registry.json"
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        registry_path.chmod(0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def test_clean_exit_strips_only_managed_pid_fields_and_preserves_mode(self):
        from tests.conftest import spawn_tracked, clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", self.name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        self.assertEqual(proc.returncode, 0, f"stdout={stdout!r} stderr={stderr!r}")

        registry_path = self.broker_root / "registry.json"
        mode = registry_path.stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)

        registrations = json.loads(registry_path.read_text(encoding="utf-8"))
        managed = next(r for r in registrations if r["session_id"] == self.name)
        self.assertNotIn("pid", managed)
        self.assertNotIn("pid_start_time", managed)
        self.assertEqual(managed["alias"], self.name)
        self.assertEqual(managed["registered_at"], 1234.5)

        peer = next(r for r in registrations if r["session_id"] == "peer")
        self.assertEqual(peer["pid"], 5252)
        self.assertEqual(peer["pid_start_time"], 8888)


@_CLI_SKIP
class C2CStartNameValidationTests(unittest.TestCase):
    """Instance name validation: `c2c start` must reject names with slashes, leading dots, etc.

    Regression for the crinkle documented in
    .collab/findings/2026-04-21T14-50-00Z-coordinator1-managed-session-crinkles.md
    where `c2c start opencode -n foo/bar` created a nested directory instead of failing.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir(parents=True)
        self.stub = self.tmp_path / "opencode"
        self.stub.write_text("#!/bin/sh\nexit 0\n")
        self.stub.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, name: str) -> tuple[int, str, str]:
        from tests.conftest import spawn_tracked, clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            # Prevent git rev-parse from finding the real repo, so
            # refresh_opencode_identity uses the broker-derived path (tmp dir)
            # rather than the real .opencode/opencode.json.
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        try:
            stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"timed out with name={name!r}")
        return proc.returncode, stdout, stderr

    def test_slash_in_name_rejected(self):
        """Names containing '/' must be rejected with a non-zero exit and error message."""
        rc, _out, stderr = self._run("foo/bar")
        self.assertNotEqual(rc, 0, "expected non-zero exit for name with slash")
        self.assertIn("foo/bar", stderr, f"invalid name not echoed in stderr: {stderr!r}")

    def test_leading_dot_rejected(self):
        """Names starting with '.' must be rejected."""
        rc, _out, stderr = self._run(".hidden")
        self.assertNotEqual(rc, 0, "expected non-zero exit for name starting with dot")

    def test_empty_name_rejected(self):
        """Empty name must be rejected."""
        rc, _out, stderr = self._run("")
        self.assertNotEqual(rc, 0, "expected non-zero exit for empty name")

    def test_valid_name_accepted(self):
        """Simple alphanumeric names with hyphens/dots/underscores must be accepted."""
        rc, _out, _err = self._run("my-valid.instance_1")
        # stub exits 0, so c2c start should also exit 0
        self.assertEqual(rc, 0, "valid name was unexpectedly rejected")

    def test_name_too_long_rejected(self):
        """Names over 64 characters must be rejected."""
        long_name = "a" * 65
        rc, _out, stderr = self._run(long_name)
        self.assertNotEqual(rc, 0, "expected non-zero exit for name exceeding 64 chars")

    def test_no_nested_dir_created_for_slash_name(self):
        """A name with '/' must not create nested directories under instances dir."""
        self._run("foo/bar")
        nested = self.instances_dir / "foo" / "bar"
        self.assertFalse(nested.exists(), f"nested dir was created: {nested}")


@_CLI_SKIP
class C2CStartModelValidationTests(unittest.TestCase):
    """Regression: `c2c start --model` must fail early for malformed client-specific values."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, client: str, model: str) -> tuple[int, str, str]:
        from tests.conftest import spawn_tracked, clean_c2c_start_env

        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", client, "-n", f"model-{client}", "--model", model],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        try:
            stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"c2c start timed out for client={client!r} model={model!r}")
        return proc.returncode, stdout, stderr

    def test_opencode_bare_model_rejected(self):
        rc, _out, stderr = self._run("opencode", "MiniMax-M2.7-highspeed")
        self.assertEqual(rc, 1, stderr)
        self.assertIn("invalid --model for client 'opencode'", stderr)
        self.assertIn("provider:model", stderr)

    def test_single_provider_client_rejects_empty_model_suffix(self):
        for client in ("claude", "codex", "codex-headless", "kimi", "crush"):
            with self.subTest(client=client):
                rc, _out, stderr = self._run(client, "anthropic:")
                self.assertEqual(rc, 1, stderr)
                self.assertIn(f"invalid --model for client '{client}'", stderr)
                self.assertIn("empty model", stderr)


@_CLI_SKIP
class PollInboxAliasFallbackTests(unittest.TestCase):
    """Regression: `c2c poll-inbox` must fall back to alias-based session_id lookup.

    Scenario: C2C_MCP_SESSION_ID=my-alias but the registry has the registration
    under session_id=real-session (alias=my-alias). The inbox file lives at
    real-session.inbox.json, NOT my-alias.inbox.json.

    Before 68283ef: poll-inbox tried my-alias.inbox.json → got [] even though
    real-session.inbox.json had messages (the planner1 session_id mismatch bug).

    After fix: poll-inbox uses alias fallback → finds real-session → drains correctly.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.tmp.name) / "broker"
        self.broker_root.mkdir(parents=True)

        # Write a registry with session_id != alias
        reg = {
            "session_id": "real-session-id",
            "alias": "my-alias",
            "pid": os.getpid(),
            "pid_start_time": 0,
            "registered_at": 0.0,
        }
        (self.broker_root / "registry.json").write_text(json.dumps([reg]))

        # Write a test message into the real session's inbox
        msg = {
            "from_alias": "sender1",
            "to_alias": "my-alias",
            "content": "hello from fallback test",
            "deferrable": False,
        }
        (self.broker_root / "real-session-id.inbox.json").write_text(json.dumps([msg]))

    def tearDown(self):
        self.tmp.cleanup()

    def _poll(self) -> tuple[int, str, str]:
        from tests.conftest import spawn_tracked
        env = {
            **os.environ,
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_MCP_SESSION_ID": "my-alias",
            "C2C_MCP_AUTO_REGISTER_ALIAS": "my-alias",
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "poll-inbox", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        return proc.returncode, stdout, stderr

    def test_alias_fallback_finds_inbox(self):
        """poll-inbox with session_id mismatch must drain the alias-resolved inbox."""
        rc, stdout, _stderr = self._poll()
        self.assertEqual(rc, 0, f"poll-inbox exited non-zero: {_stderr}")
        msgs = json.loads(stdout)
        self.assertEqual(len(msgs), 1, f"expected 1 message via alias fallback, got: {msgs}")
        self.assertEqual(msgs[0]["from_alias"], "sender1")
        self.assertEqual(msgs[0]["content"], "hello from fallback test")

    def test_alias_fallback_prints_info_to_stderr(self):
        """poll-inbox alias fallback must log a diagnostic to stderr so the mismatch is visible."""
        _rc, _stdout, stderr = self._poll()
        self.assertIn("my-alias", stderr, f"alias not mentioned in stderr: {stderr!r}")
        self.assertIn("real-session-id", stderr, f"resolved session_id not in stderr: {stderr!r}")

    def test_no_fallback_when_no_alias_env(self):
        """Without C2C_MCP_AUTO_REGISTER_ALIAS, poll-inbox must NOT fall back — returns []."""
        from tests.conftest import spawn_tracked
        env = {
            **os.environ,
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_MCP_SESSION_ID": "my-alias",
            # deliberately omit C2C_MCP_AUTO_REGISTER_ALIAS
        }
        env.pop("C2C_MCP_AUTO_REGISTER_ALIAS", None)
        proc = spawn_tracked(
            [str(CLI_EXE), "poll-inbox", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
        self.assertEqual(proc.returncode, 0)
        msgs = json.loads(stdout)
        # Without the alias env, it looks for my-alias.inbox.json which doesn't exist → []
        self.assertEqual(msgs, [], f"expected [] without alias env, got: {msgs}")


class C2CStartKickoffPromptTests(unittest.TestCase):
    """Tests for --auto kickoff prompt and role file behaviors."""

    CLI_TIMEOUT = 10

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir()
        # Create .opencode dir so kickoff-prompt.txt write succeeds
        (self.tmp_path / ".opencode").mkdir()
        # Stub opencode binary that exits 0
        stub = self.tmp_path / "opencode"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _run_start_auto(self, name: str, role: str | None = None) -> tuple[int, str, str]:
        from tests.conftest import spawn_tracked, clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        if role is not None:
            roles_dir = self.tmp_path / ".c2c" / "roles"
            roles_dir.mkdir(parents=True, exist_ok=True)
            (roles_dir / f"{name}.md").write_text(role)
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "--auto", "-n", name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(self.tmp_path),
        )
        try:
            stdout, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(f"c2c start timed out")
        return proc.returncode, stdout, stderr

    def test_auto_writes_kickoff_prompt_file(self):
        """--auto must write per-instance kickoff-prompt.txt before launching."""
        self._run_start_auto("kp-test-agent")
        # Written to per-instance dir (C2C_INSTANCES_DIR/name/) so concurrent
        # launches don't clobber each other's shared .opencode/kickoff-prompt.txt
        kp = self.instances_dir / "kp-test-agent" / "kickoff-prompt.txt"
        self.assertTrue(kp.exists(), "kickoff-prompt.txt must be written with --auto")

    def test_kickoff_prompt_contains_alias(self):
        """kickoff-prompt.txt must mention the agent's alias."""
        self._run_start_auto("kp-alias-agent")
        kp = (self.instances_dir / "kp-alias-agent" / "kickoff-prompt.txt").read_text()
        self.assertIn("kp-alias-agent", kp)

    def test_kickoff_prompt_contains_role_when_set(self):
        """kickoff-prompt.txt must include the role when a role file exists."""
        self._run_start_auto("kp-role-agent", role="senior planner and coordinator")
        kp = (self.instances_dir / "kp-role-agent" / "kickoff-prompt.txt").read_text()
        self.assertIn("senior planner and coordinator", kp)

    def test_no_kickoff_prompt_without_auto(self):
        """Without --auto and no role, kickoff-prompt.txt must not be written."""
        from tests.conftest import spawn_tracked
        env = {
            **os.environ,
            "PATH": str(self.tmp_path) + ":" + os.environ.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
            "GIT_DIR": str(self.tmp_path / "no-such-git"),
        }
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", "no-auto-agent"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=env, cwd=str(self.tmp_path),
        )
        try:
            proc.communicate(timeout=self.CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
        kp = self.instances_dir / "no-auto-agent" / "kickoff-prompt.txt"
        self.assertFalse(kp.exists(), "kickoff-prompt.txt must not be written without --auto")


@unittest.skipUnless(_CLI_BUILT, "c2c.exe not built")
class C2CStartInstallPromptTests(unittest.TestCase):
    """Tests for the 'opencode.json missing → prompt to run install' feature (#59)."""

    CLI_TIMEOUT = 10

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.broker_root = self.tmp_path / "broker"
        self.broker_root.mkdir(parents=True)
        self.instances_dir = self.tmp_path / "instances"
        self.instances_dir.mkdir()
        # .opencode dir WITHOUT opencode.json — triggers the install check
        (self.tmp_path / ".opencode").mkdir()
        # Stub opencode binary that exits immediately
        stub = self.tmp_path / "opencode"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o755)
        # Marker file used by the fake `c2c` wrapper to confirm install was called
        self.install_marker = self.tmp_path / "install-called"
        # Stub c2c script: when called as 'c2c install opencode', writes the marker;
        # otherwise falls through to the real c2c binary so broker ops still work.
        real_c2c = str(CLI_EXE)
        stub_c2c = self.tmp_path / "c2c"
        stub_c2c.write_text(
            "#!/bin/sh\n"
            f"if [ \"$1\" = 'install' ] && [ \"$2\" = 'opencode' ]; then\n"
            f"  touch {self.install_marker}\n"
            "  exit 0\n"
            "fi\n"
            f"exec {real_c2c} \"$@\"\n"
        )
        stub_c2c.chmod(0o755)
        # Initialize a bare git repo so resolve_repo_root returns a non-empty path.
        # Without this, project_dir="" and the install check is skipped entirely.
        subprocess.run(["git", "init", "-q", str(self.tmp_path)], check=True)
        # Pre-seed role files so prompt_for_role skips the interactive role prompt
        # on TTY tests. Otherwise 'n' or 'y' would be consumed by the role prompt
        # before reaching the install prompt.
        roles_dir = self.tmp_path / ".c2c" / "roles"
        roles_dir.mkdir(parents=True, exist_ok=True)
        for alias in ("install-nontty", "install-noprompt", "install-skip",
                      "install-yes", "install-already"):
            (roles_dir / f"{alias}.md").write_text("test agent")

    def tearDown(self):
        self.tmp.cleanup()

    def _base_env(self):
        from tests.conftest import clean_c2c_start_env
        base_env = clean_c2c_start_env(os.environ)
        env = {
            **base_env,
            "PATH": str(self.tmp_path) + ":" + base_env.get("PATH", ""),
            "C2C_MCP_BROKER_ROOT": str(self.broker_root),
            "C2C_INSTANCES_DIR": str(self.instances_dir),
        }
        # Remove any inherited GIT_DIR/GIT_WORK_TREE so the subprocess uses
        # the git repo we initialized in setUp rather than any parent repo.
        env.pop("GIT_DIR", None)
        env.pop("GIT_WORK_TREE", None)
        return env

    def test_non_tty_silently_runs_install(self):
        """Non-TTY stdin (pipe) must silently run c2c install opencode."""
        from tests.conftest import spawn_tracked
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", "install-nontty"],
            stdin=subprocess.DEVNULL,   # not a TTY → silent install
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=self._base_env(), cwd=str(self.tmp_path),
        )
        try:
            _, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.communicate()
            self.fail("c2c start timed out")
        self.assertTrue(self.install_marker.exists(),
                        f"install marker missing — install was not called. stderr: {stderr}")
        self.assertIn("opencode.json not found", stderr)

    def test_non_tty_no_interactive_prompt(self):
        """Non-TTY stdin must NOT show 'Run it now?' prompt."""
        from tests.conftest import spawn_tracked
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", "install-noprompt"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=self._base_env(), cwd=str(self.tmp_path),
        )
        try:
            _, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.communicate()
            self.fail("c2c start timed out")
        self.assertNotIn("Run it now?", stderr)

    def test_tty_answer_n_skips_install(self):
        """TTY stdin with 'n' answer must skip install and warn."""
        import pty
        master_fd, slave_fd = pty.openpty()
        from tests.conftest import spawn_tracked
        try:
            proc = spawn_tracked(
                [str(CLI_EXE), "start", "opencode", "-n", "install-skip"],
                stdin=slave_fd,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                env=self._base_env(), cwd=str(self.tmp_path),
                close_fds=True,
            )
            os.close(slave_fd)
            slave_fd = -1
            os.write(master_fd, b"n\n")
            try:
                _, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.communicate()
                self.fail("c2c start timed out")
        finally:
            os.close(master_fd)
            if slave_fd != -1:
                os.close(slave_fd)
        self.assertFalse(self.install_marker.exists(),
                         "install must NOT be called when user answers 'n'")
        self.assertIn("skipping install", stderr)

    def test_tty_answer_y_runs_install(self):
        """TTY stdin with 'y' answer must run c2c install opencode."""
        import pty
        master_fd, slave_fd = pty.openpty()
        from tests.conftest import spawn_tracked
        try:
            proc = spawn_tracked(
                [str(CLI_EXE), "start", "opencode", "-n", "install-yes"],
                stdin=slave_fd,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                env=self._base_env(), cwd=str(self.tmp_path),
                close_fds=True,
            )
            os.close(slave_fd)
            slave_fd = -1
            os.write(master_fd, b"y\n")
            try:
                _, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.communicate()
                self.fail("c2c start timed out")
        finally:
            os.close(master_fd)
            if slave_fd != -1:
                os.close(slave_fd)
        self.assertTrue(self.install_marker.exists(),
                        f"install must be called when user answers 'y'. stderr: {stderr}")

    def test_no_prompt_when_opencode_json_exists(self):
        """When opencode.json already exists, no prompt and no install call."""
        (self.tmp_path / ".opencode" / "opencode.json").write_text('{"mcp":{}}')
        from tests.conftest import spawn_tracked
        proc = spawn_tracked(
            [str(CLI_EXE), "start", "opencode", "-n", "install-already"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=self._base_env(), cwd=str(self.tmp_path),
        )
        try:
            _, stderr = proc.communicate(timeout=self.CLI_TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.communicate()
            self.fail("c2c start timed out")
        self.assertFalse(self.install_marker.exists(),
                         "install must NOT be called when opencode.json already exists")
        self.assertNotIn("Run it now?", stderr)
        self.assertNotIn("opencode.json not found", stderr)


if __name__ == "__main__":
    unittest.main()
