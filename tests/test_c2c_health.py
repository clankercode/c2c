import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))


class HealthCheckRegistryTests(unittest.TestCase):
    """Tests for c2c_health.check_registry()."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_no_registry_returns_exists_false(self):
        import c2c_health

        result = c2c_health.check_registry(self.broker_root)
        self.assertFalse(result["exists"])
        self.assertEqual(result["entry_count"], 0)
        self.assertEqual(result["duplicate_pids"], [])

    def test_empty_registry_has_no_duplicates(self):
        import c2c_health

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        result = c2c_health.check_registry(self.broker_root)
        self.assertTrue(result["exists"])
        self.assertEqual(result["entry_count"], 0)
        self.assertEqual(result["duplicate_pids"], [])

    def test_unique_pids_have_no_duplicates(self):
        import c2c_health

        regs = [
            {"session_id": "s1", "alias": "a1", "pid": 100},
            {"session_id": "s2", "alias": "a2", "pid": 200},
        ]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )
        result = c2c_health.check_registry(self.broker_root)
        self.assertEqual(result["entry_count"], 2)
        self.assertEqual(result["duplicate_pids"], [])

    def test_duplicate_pids_are_reported(self):
        import c2c_health

        regs = [
            {"session_id": "s1", "alias": "a1", "pid": 100},
            {"session_id": "s2", "alias": "a2", "pid": 100},
            {"session_id": "s3", "alias": "a3", "pid": 200},
        ]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )
        result = c2c_health.check_registry(self.broker_root)
        self.assertEqual(result["entry_count"], 3)
        self.assertEqual(len(result["duplicate_pids"]), 1)
        self.assertEqual(result["duplicate_pids"][0]["pid"], 100)
        self.assertEqual(sorted(result["duplicate_pids"][0]["aliases"]), ["a1", "a2"])
        self.assertEqual(result["duplicate_pids"][0]["likely_stale_aliases"], [])

    def test_duplicate_pids_identify_zero_activity_alias_as_likely_stale(self):
        import c2c_health

        regs = [
            {"session_id": "codex-local", "alias": "codex", "pid": 100},
            {
                "session_id": "opencode-c2c-msg",
                "alias": "opencode-c2c-msg",
                "pid": 100,
            },
        ]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )
        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir()
        (archive_dir / "codex-local.jsonl").write_text(
            json.dumps(
                {
                    "from_alias": "codex",
                    "to_alias": "peer",
                    "content": "activity",
                }
            )
            + "\n",
            encoding="utf-8",
        )

        result = c2c_health.check_registry(self.broker_root)

        self.assertEqual(result["duplicate_pids"][0]["likely_stale_aliases"], ["opencode-c2c-msg"])

    def test_entries_without_pid_are_ignored_for_duplicate_check(self):
        import c2c_health

        regs = [
            {"session_id": "s1", "alias": "a1"},
            {"session_id": "s2", "alias": "a2"},
        ]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )
        result = c2c_health.check_registry(self.broker_root)
        self.assertEqual(result["entry_count"], 2)
        self.assertEqual(result["duplicate_pids"], [])


class HealthCheckHookTests(unittest.TestCase):
    """Tests for c2c_health.check_hook()."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.home = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _hook_path(self):
        return self.home / ".claude" / "hooks" / "c2c-inbox-check.sh"

    def _settings_path(self):
        return self.home / ".claude" / "settings.json"

    def _write_hook(self, executable: bool = True) -> None:
        hook = self._hook_path()
        hook.parent.mkdir(parents=True, exist_ok=True)
        hook.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        if executable:
            hook.chmod(0o755)

    def _write_settings(self, has_c2c: bool = True) -> None:
        settings = self._settings_path()
        settings.parent.mkdir(parents=True, exist_ok=True)
        if has_c2c:
            payload = {
                "hooks": {
                    "PostToolUse": [
                        {
                            "matcher": ".*",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "/home/user/.claude/hooks/c2c-inbox-check.sh",
                                }
                            ],
                        }
                    ]
                }
            }
        else:
            payload = {"hooks": {"PostToolUse": []}}
        settings.write_text(json.dumps(payload), encoding="utf-8")

    def test_no_hook_file_returns_not_ok(self):
        import c2c_health

        result = c2c_health.check_hook(self.home)
        self.assertFalse(result["hook_exists"])
        self.assertFalse(result["ok"])

    def test_hook_exists_but_not_in_settings_returns_partial(self):
        import c2c_health

        self._write_hook()
        self._write_settings(has_c2c=False)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertTrue(result["hook_executable"])
        self.assertFalse(result["settings_registered"])
        self.assertFalse(result["ok"])

    def test_hook_and_settings_both_present_returns_ok(self):
        import c2c_health

        self._write_hook()
        self._write_settings(has_c2c=True)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertTrue(result["hook_executable"])
        self.assertTrue(result["settings_registered"])
        self.assertTrue(result["ok"])

    def test_non_executable_hook_returns_not_ok(self):
        import c2c_health

        self._write_hook(executable=False)
        self._write_settings(has_c2c=True)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertFalse(result["hook_executable"])
        self.assertFalse(result["ok"])


class HealthCheckSwarmLoungeTests(unittest.TestCase):
    """Tests for c2c_health.check_swarm_lounge()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_no_alias_returns_not_member(self):
        import c2c_health

        result = c2c_health.check_swarm_lounge(self.broker_root, None)
        self.assertFalse(result["member"])
        self.assertFalse(result["room_exists"])

    def test_room_missing_returns_not_member(self):
        import c2c_health

        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertFalse(result["member"])
        self.assertFalse(result["room_exists"])

    def test_alias_in_members_returns_member(self):
        import c2c_health

        lounge = self.broker_root / "rooms" / "swarm-lounge"
        lounge.mkdir(parents=True)
        (lounge / "members.json").write_text(
            json.dumps([{"alias": "my-alias", "session_id": "s1"}]),
            encoding="utf-8",
        )
        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertTrue(result["member"])
        self.assertTrue(result["room_exists"])

    def test_alias_not_in_members_returns_not_member(self):
        import c2c_health

        lounge = self.broker_root / "rooms" / "swarm-lounge"
        lounge.mkdir(parents=True)
        (lounge / "members.json").write_text(
            json.dumps([{"alias": "other-alias", "session_id": "s1"}]),
            encoding="utf-8",
        )
        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertFalse(result["member"])
        self.assertTrue(result["room_exists"])


class HealthCheckSessionInboxPendingTests(unittest.TestCase):
    """Tests for inbox_pending count in c2c_health.check_session()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, session_id: str, alias: str) -> None:
        import os

        self.registry_path.write_text(
            json.dumps(
                [
                    {
                        "session_id": session_id,
                        "alias": alias,
                        "pid": os.getpid(),
                        "pid_start_time": 1,
                    }
                ]
            ),
            encoding="utf-8",
        )

    def test_inbox_pending_is_zero_for_empty_inbox(self):
        import c2c_health

        self._write_registry("ses-empty", "agent-empty")
        inbox = self.broker_root / "ses-empty.inbox.json"
        inbox.write_text("[]", encoding="utf-8")

        result = c2c_health.check_session(self.broker_root, session_id="ses-empty")
        self.assertTrue(result["registered"])
        self.assertEqual(result["inbox_pending"], 0)

    def test_inbox_pending_counts_messages(self):
        import c2c_health

        self._write_registry("ses-msgs", "agent-msgs")
        msgs = [
            {"from_alias": "peer-a", "to_alias": "agent-msgs", "content": "hello"},
            {"from_alias": "peer-b", "to_alias": "agent-msgs", "content": "world"},
            {"from_alias": "peer-c", "to_alias": "agent-msgs", "content": "sup"},
        ]
        inbox = self.broker_root / "ses-msgs.inbox.json"
        inbox.write_text(json.dumps(msgs), encoding="utf-8")

        result = c2c_health.check_session(self.broker_root, session_id="ses-msgs")
        self.assertTrue(result["registered"])
        self.assertEqual(result["inbox_pending"], 3)

    def test_inbox_pending_zero_when_inbox_missing(self):
        import c2c_health

        self._write_registry("ses-nofile", "agent-nofile")
        # No inbox file created

        result = c2c_health.check_session(self.broker_root, session_id="ses-nofile")
        self.assertTrue(result["registered"])
        self.assertFalse(result["inbox_exists"])
        self.assertEqual(result["inbox_pending"], 0)


class HealthCheckSessionMcpSessionIdTests(unittest.TestCase):
    """Tests for C2C_MCP_SESSION_ID fallback in c2c_health.check_session()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, session_id: str, alias: str) -> None:
        import os

        self.registry_path.write_text(
            json.dumps(
                [
                    {
                        "session_id": session_id,
                        "alias": alias,
                        "pid": os.getpid(),
                        "pid_start_time": 1,
                    }
                ]
            ),
            encoding="utf-8",
        )

    def test_mcp_session_id_resolves_when_no_explicit_session_id(self):
        """C2C_MCP_SESSION_ID env var is used as fallback for session resolution."""
        import c2c_health

        self._write_registry("mcp-sid-abc123", "storm-beacon")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "mcp-sid-abc123"}, clear=False
        ):
            # Remove env vars that would interfere with whoami resolution
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("C2C_SESSION_ID", "C2C_SESSION_PID")
            }
            env["C2C_MCP_SESSION_ID"] = "mcp-sid-abc123"
            with mock.patch.dict(os.environ, env, clear=True):
                result = c2c_health.check_session(self.broker_root)

        self.assertTrue(result["resolved"])
        self.assertTrue(result["registered"])
        self.assertEqual(result["alias"], "storm-beacon")
        self.assertEqual(result["session_id"], "mcp-sid-abc123")

    def test_mcp_session_id_not_in_registry_gives_unregistered(self):
        """C2C_MCP_SESSION_ID set but not registered yields resolved=True, registered=False."""
        import c2c_health

        # Registry is empty
        self.registry_path.write_text("[]", encoding="utf-8")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "unknown-sid-xyz"}, clear=False
        ):
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("C2C_SESSION_ID", "C2C_SESSION_PID")
            }
            env["C2C_MCP_SESSION_ID"] = "unknown-sid-xyz"
            with mock.patch("c2c_whoami.resolve_identity", return_value=(None, None)):
                with mock.patch.dict(os.environ, env, clear=True):
                    result = c2c_health.check_session(self.broker_root)

        self.assertTrue(result["resolved"])
        self.assertFalse(result["registered"])

    def test_explicit_session_id_arg_takes_priority_over_mcp_env(self):
        """Explicit session_id arg bypasses C2C_MCP_SESSION_ID env var."""
        import c2c_health

        self._write_registry("explicit-sid-999", "operator-alias")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "mcp-sid-should-be-ignored"}, clear=False
        ):
            result = c2c_health.check_session(
                self.broker_root, session_id="explicit-sid-999"
            )

        self.assertTrue(result["registered"])
        self.assertEqual(result["alias"], "operator-alias")
        self.assertEqual(result["session_id"], "explicit-sid-999")
        self.assertTrue(result["operator_check"])


class HealthCheckWireDaemonTests(unittest.TestCase):
    """Tests for c2c_health.check_wire_daemon()."""

    def test_no_session_id_skips_wire_daemon_check(self):
        import c2c_health

        result = c2c_health.check_wire_daemon(None)

        self.assertFalse(result["checked"])

    def test_wire_daemon_status_is_reported_for_session_id(self):
        import c2c_health

        status = {
            "running": True,
            "pid": 12345,
            "pidfile": "/tmp/kimi-test.pid",
        }
        with mock.patch("c2c_wire_daemon._daemon_status", return_value=status):
            result = c2c_health.check_wire_daemon("kimi-test")

        self.assertTrue(result["checked"])
        self.assertTrue(result["running"])
        self.assertEqual(result["pid"], 12345)
        self.assertEqual(result["pidfile"], "/tmp/kimi-test.pid")

    def test_wire_daemon_falls_back_to_pgrep_when_pidfile_is_stale(self):
        import c2c_health

        status = {
            "running": False,
            "pid": 99999,
            "pidfile": "/tmp/kimi-test.pid",
        }
        pgrep_output = "12345 python3 /path/c2c_kimi_wire_bridge.py --session-id kimi-test --alias kimi-test-2\n"
        with (
            mock.patch("c2c_wire_daemon._daemon_status", return_value=status),
            mock.patch(
                "subprocess.run",
                return_value=mock.Mock(stdout=pgrep_output, stderr=""),
            ) as run_mock,
        ):
            result = c2c_health.check_wire_daemon("kimi-test")

        self.assertTrue(result["checked"])
        self.assertTrue(result["running"])
        self.assertEqual(result["pid"], 12345)
        self.assertEqual(result["fallback"], "pgrep")
        run_mock.assert_called_once()
        args, _ = run_mock.call_args
        self.assertEqual(args[0][0], "pgrep")

    def test_run_health_check_uses_resolved_session_for_wire_daemon_check(self):
        import c2c_health

        session = {
            "resolved": True,
            "registered": True,
            "alias": "kimi-agent",
            "session_id": "kimi-agent",
            "inbox_exists": True,
            "inbox_writable": True,
            "operator_check": False,
        }
        with (
            mock.patch("c2c_health.check_session", return_value=session),
            mock.patch("c2c_health.check_broker_root", return_value={}),
            mock.patch("c2c_health.check_registry", return_value={}),
            mock.patch("c2c_health.check_rooms", return_value={}),
            mock.patch("c2c_health.check_hook", return_value={}),
            mock.patch("c2c_health.check_swarm_lounge", return_value={}),
            mock.patch("c2c_health.check_dead_letter", return_value={}),
            mock.patch("c2c_health.check_stale_inboxes", return_value={}),
            mock.patch("c2c_health.check_outer_loops", return_value={}),
            mock.patch("c2c_health.check_relay", return_value={}),
            mock.patch("c2c_health.check_broker_binary", return_value={}),
            mock.patch("c2c_health.check_wire_daemon") as check_wire,
        ):
            c2c_health.run_health_check(Path("/tmp/broker"))

        check_wire.assert_called_once_with("kimi-agent")


class WireDaemonLifecycleTests(unittest.TestCase):
    """Tests for c2c_wire_daemon lifecycle behavior."""

    def test_start_refreshes_broker_registration_to_daemon_pid(self):
        import argparse
        import c2c_wire_daemon

        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir) / "state"
            broker_root = Path(temp_dir) / "broker"
            broker_root.mkdir()
            args = argparse.Namespace(
                session_id="kimi-nova",
                alias="kimi-nova-2",
                broker_root=str(broker_root),
                interval=5.0,
                command=None,
                timeout=5.0,
                json=True,
            )

            with (
                mock.patch("c2c_wire_daemon._state_dir", return_value=state_dir),
                mock.patch(
                    "c2c_kimi_wire_bridge.start_daemon",
                    return_value={"ok": True, "pid": 12345},
                ),
                mock.patch("c2c_refresh_peer.refresh_peer", return_value={}) as refresh,
                mock.patch("sys.stdout", io.StringIO()),
            ):
                rc = c2c_wire_daemon.cmd_start(args)

        self.assertEqual(rc, 0)
        refresh.assert_called_once_with(
            "kimi-nova-2",
            12345,
            broker_root,
            session_id="kimi-nova",
        )

    def test_list_includes_running_processes_without_pidfile(self):
        import argparse
        import c2c_wire_daemon

        pgrep_output = (
            "748416 python3 /path/c2c_kimi_wire_bridge.py --session-id kimi-nova --alias kimi-nova-2 --loop\n"
        )
        with (
            mock.patch("c2c_wire_daemon._state_dir", return_value=Path("/nonexistent")),
            mock.patch(
                "subprocess.run",
                return_value=mock.Mock(stdout=pgrep_output, stderr=""),
            ),
            mock.patch("sys.stdout", io.StringIO()) as buf,
        ):
            args = argparse.Namespace(json=False)
            rc = c2c_wire_daemon.cmd_list(args)

        self.assertEqual(rc, 0)
        output = buf.getvalue()
        self.assertIn("kimi-nova", output)
        self.assertIn("kimi-nova-2", output)
        self.assertIn("pid 748416", output)

    def test_list_enriches_pidfile_status_with_alias_from_pgrep(self):
        import argparse
        import c2c_wire_daemon

        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir) / "state"
            state_dir.mkdir()
            (state_dir / "kimi-nova.pid").write_text("748416")

            pgrep_output = (
                "748416 python3 /path/c2c_kimi_wire_bridge.py --session-id kimi-nova --alias kimi-nova-2 --loop\n"
            )
            with (
                mock.patch("c2c_wire_daemon._state_dir", return_value=state_dir),
                mock.patch(
                    "subprocess.run",
                    return_value=mock.Mock(stdout=pgrep_output, stderr=""),
                ),
                mock.patch("c2c_wire_daemon._pid_is_alive", return_value=True),
                mock.patch("sys.stdout", io.StringIO()) as buf,
            ):
                args = argparse.Namespace(json=False)
                rc = c2c_wire_daemon.cmd_list(args)

        self.assertEqual(rc, 0)
        output = buf.getvalue()
        self.assertIn("kimi-nova", output)
        self.assertIn("alias=kimi-nova-2", output)
        self.assertIn("pid 748416", output)
        # Should NOT show (pgrep) because pidfile existed
        self.assertNotIn("(pgrep)", output)


class HealthCheckBrokerBinaryTests(unittest.TestCase):
    """Tests for c2c_health.check_broker_binary()."""

    def test_binary_does_not_exist_returns_not_exists(self):
        import c2c_health

        with (
            mock.patch(
                "c2c_mcp.built_server_path",
                return_value=Path("/nonexistent/c2c_mcp_server.exe"),
            ),
        ):
            result = c2c_health.check_broker_binary()

        self.assertFalse(result["exists"])
        self.assertFalse(result["fresh"])

    def test_fresh_binary_reports_version_and_fresh(self, tmp_path=None):
        import c2c_health
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".exe", delete=False) as fh:
            bin_path = Path(fh.name)
        try:
            with (
                mock.patch("c2c_mcp.built_server_path", return_value=bin_path),
                mock.patch("c2c_mcp.server_is_fresh", return_value=True),
                mock.patch(
                    "pathlib.Path.read_text",
                    return_value='let server_version = "0.6.6"\nother code\n',
                ),
            ):
                result = c2c_health.check_broker_binary()
        finally:
            bin_path.unlink(missing_ok=True)

        self.assertTrue(result["exists"])
        self.assertTrue(result["fresh"])
        self.assertEqual(result.get("source_version"), "0.6.6")

    def test_stale_binary_reports_not_fresh(self):
        import c2c_health
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".exe", delete=False) as fh:
            bin_path = Path(fh.name)
        try:
            with (
                mock.patch("c2c_mcp.built_server_path", return_value=bin_path),
                mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            ):
                result = c2c_health.check_broker_binary()
        finally:
            bin_path.unlink(missing_ok=True)

        self.assertTrue(result["exists"])
        self.assertFalse(result["fresh"])


class ServerIsFreshTests(unittest.TestCase):
    """Tests for c2c_mcp.server_is_fresh() — freshness check excludes test/ dir."""

    def test_fresh_when_binary_newer_than_sources(self):
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            ocaml_dir.mkdir()
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            import time

            time.sleep(0.05)
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            # Binary is newer than source — should be fresh.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertTrue(c2c_mcp.server_is_fresh(bin_path))

    def test_stale_when_source_newer_than_binary(self):
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            ocaml_dir.mkdir()
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            import time

            time.sleep(0.05)
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            # Source is newer than binary — should be stale.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertFalse(c2c_mcp.server_is_fresh(bin_path))

    def test_test_dir_sources_excluded_from_freshness_check(self):
        """Test files under ocaml/test/ must not trigger stale when newer than binary."""
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            test_dir = ocaml_dir / "test"
            test_dir.mkdir(parents=True)
            # Server source (older)
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            import time

            time.sleep(0.05)
            # Binary (newer than server source)
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            import time

            time.sleep(0.05)
            # Test file (newest — but should be excluded from check)
            test_src = test_dir / "test_c2c_mcp.ml"
            test_src.write_text("let () = ()\n")
            # Despite test file being newer than binary, should still be fresh.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertTrue(c2c_mcp.server_is_fresh(bin_path))


class HealthCheckStaleInboxTests(unittest.TestCase):
    """Tests for c2c_health.check_stale_inboxes()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_inbox(self, session_id: str, messages: list) -> None:
        path = self.broker_root / f"{session_id}.inbox.json"
        path.write_text(json.dumps(messages), encoding="utf-8")

    def _write_registry(self, registrations: list[dict]) -> None:
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def _write_archive_entry(self, session_id: str, entry: dict) -> None:
        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir(parents=True, exist_ok=True)
        path = archive_dir / f"{session_id}.jsonl"
        path.write_text(json.dumps(entry) + "\n", encoding="utf-8")

    def test_empty_broker_dir_returns_no_stale(self):
        result = self.c2c_health.check_stale_inboxes(self.broker_root)
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["total_pending"], 0)

    def test_empty_inbox_not_reported(self):
        self._write_inbox("sess-a", [])
        result = self.c2c_health.check_stale_inboxes(self.broker_root)
        self.assertEqual(result["stale"], [])

    def test_inbox_below_threshold_not_reported(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 3)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["total_pending"], 3)

    def test_inbox_at_threshold_reported(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 5)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(len(result["stale"]), 1)
        self.assertEqual(result["stale"][0]["session_id"], "sess-a")
        self.assertEqual(result["stale"][0]["count"], 5)

    def test_alias_resolved_from_registry(self):
        self._write_registry(
            [{"session_id": "sess-a", "alias": "nice-agent", "pid": os.getpid()}]
        )
        self._write_inbox("sess-a", [{"content": "m"}] * 10)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"][0]["alias"], "nice-agent")

    def test_session_id_used_as_alias_when_not_in_registry(self):
        self._write_inbox("unknown-sess", [{"content": "m"}] * 10)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"][0]["alias"], "unknown-sess")

    def test_total_pending_counts_all_inboxes(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 2)
        self._write_inbox("sess-b", [{"content": "m"}] * 8)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["total_pending"], 10)
        self.assertEqual(result["below_threshold_pending"], 2)
        self.assertEqual(result["below_threshold_inbox_count"], 1)
        self.assertEqual(len(result["stale"]), 1)  # only sess-b >= threshold

    def test_dead_registered_inbox_is_reported_separately_from_live_stale(self):
        self._write_registry(
            [
                {"session_id": "live-sess", "alias": "live-agent", "pid": os.getpid()},
                {"session_id": "dead-sess", "alias": "dead-agent", "pid": 99999999},
            ]
        )
        self._write_inbox("live-sess", [{"content": "m"}] * 6)
        self._write_inbox("dead-sess", [{"content": "m"}] * 7)

        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)

        self.assertEqual([entry["alias"] for entry in result["stale"]], ["live-agent"])
        self.assertEqual(
            [entry["alias"] for entry in result["inactive_stale"]],
            ["dead-agent"],
        )
        self.assertEqual(result["inactive_pending"], 7)

    def test_duplicate_pid_zero_activity_inbox_reported_as_inactive_artifact(self):
        pid = os.getpid()
        self._write_registry(
            [
                {"session_id": "codex-local", "alias": "codex", "pid": pid},
                {
                    "session_id": "opencode-c2c-msg",
                    "alias": "opencode-c2c-msg",
                    "pid": pid,
                },
            ]
        )
        self._write_archive_entry(
            "codex-local",
            {"drained_at": 123.0, "from_alias": "codex", "to_alias": "peer"},
        )
        self._write_inbox("opencode-c2c-msg", [{"content": "m"}] * 7)

        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)

        self.assertEqual(result["stale"], [])
        self.assertEqual(
            [entry["alias"] for entry in result["inactive_stale"]],
            ["opencode-c2c-msg"],
        )
        self.assertEqual(result["inactive_pending"], 7)

    def test_unregistered_inbox_is_reported_as_inactive_artifact(self):
        self._write_registry([])
        self._write_inbox("proof-session", [{"content": "m"}] * 5)

        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)

        self.assertEqual(result["stale"], [])
        self.assertEqual(result["inactive_stale"][0]["session_id"], "proof-session")
        self.assertEqual(result["inactive_stale"][0]["alive"], None)

    def test_no_registry_preserves_unknown_inbox_as_actionable_stale(self):
        self._write_inbox("legacy-session", [{"content": "m"}] * 5)

        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)

        self.assertEqual(result["stale"][0]["session_id"], "legacy-session")
        self.assertEqual(result["inactive_stale"], [])


class HealthCheckDeliverDaemonTests(unittest.TestCase):
    """Tests for c2c_health.check_deliver_daemon()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health

    def test_no_session_id_returns_unchecked(self):
        result = self.c2c_health.check_deliver_daemon(None)
        self.assertFalse(result["checked"])
        self.assertFalse(result["running"])

    def test_running_when_session_id_in_pgrep_output(self):
        fake_stdout = (
            "338330 python3 c2c_deliver_inbox.py --client codex --session-id codex-local\n"
            "3771272 python3 c2c_deliver_inbox.py --client kimi --session-id kimi-nova\n"
        )
        with mock.patch(
            "subprocess.run",
            return_value=mock.Mock(stdout=fake_stdout, stderr=""),
        ) as mock_run:
            result = self.c2c_health.check_deliver_daemon("kimi-nova")
            mock_run.assert_called_once()
            self.assertTrue(result["checked"])
            self.assertTrue(result["running"])
            self.assertEqual(result["pid"], 3771272)

    def test_not_running_when_session_id_missing(self):
        fake_stdout = "338330 python3 c2c_deliver_inbox.py --client codex --session-id codex-local\n"
        with mock.patch(
            "subprocess.run",
            return_value=mock.Mock(stdout=fake_stdout, stderr=""),
        ):
            result = self.c2c_health.check_deliver_daemon("opencode-local")
            self.assertTrue(result["checked"])
            self.assertFalse(result["running"])
            self.assertIsNone(result["pid"])

    def test_pgrep_error_returns_not_running(self):
        with mock.patch(
            "subprocess.run",
            side_effect=OSError("pgrep not found"),
        ):
            result = self.c2c_health.check_deliver_daemon("kimi-nova")
            self.assertTrue(result["checked"])
            self.assertFalse(result["running"])


class HealthPrintDeliverDaemonTests(unittest.TestCase):
    """Tests for deliver-daemon/hook interaction in print_health_report()."""

    def _make_report(self, *, hook_registered: bool, daemon_running: bool) -> dict:
        """Build a minimal health report dict for print_health_report testing."""
        return {
            "session": {
                "session_id": "sid-abc",
                "alias": "test-alias",
                "registered": True,
                "resolved": True,
                "operator_check": False,
                "inbox_exists": True,
                "inbox_writable": True,
                "inbox_pending": 0,
            },
            "broker_root": {"path": "/tmp/broker", "exists": True, "writable": True},
            "registry": {
                "path": "/tmp/broker/registry.json",
                "exists": True,
                "readable": True,
                "entry_count": 1,
                "duplicate_pids": [],
            },
            "hook": {
                "hook_exists": hook_registered,
                "hook_executable": hook_registered,
                "settings_registered": hook_registered,
            },
            "claude_mcp": {"configured": False},
            "claude_wake_daemon": {"checked": False},
            "deliver_daemon": {
                "checked": True,
                "running": daemon_running,
                "pid": 12345 if daemon_running else None,
            },
            "swarm_lounge": {
                "alias": "test-alias",
                "member": True,
                "room_exists": True,
            },
            "dead_letter": {"count": 0},
            "stale_inboxes": {"stale": [], "total_pending": 0},
            "rooms": {"exists": True, "room_count": 0},
            "outer_loops": {"running": [], "count": 0},
            "broker_binary": {"checked": False},
            "relay": {"configured": False},
            "wire_daemon": {"checked": False},
        }

    def _capture_output(self, report: dict) -> str:
        import c2c_health

        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_health.print_health_report(report)
        return buf.getvalue()

    def test_deliver_daemon_warning_suppressed_when_hook_active(self):
        """No deliver-daemon warning for Claude Code sessions with hook active."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=True, daemon_running=False)
        output = self._capture_output(report)
        self.assertNotIn("Deliver daemon: not running", output)
        self.assertNotIn("c2c_deliver_inbox.py", output)

    def test_deliver_daemon_warning_shown_when_hook_not_active(self):
        """Deliver-daemon warning shown for non-Claude-Code sessions."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=False, daemon_running=False)
        output = self._capture_output(report)
        self.assertIn("Deliver daemon: not running", output)
        self.assertIn("c2c_deliver_inbox.py", output)

    def test_deliver_daemon_ok_shown_when_running(self):
        """Running deliver daemon always shows as green regardless of hook."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=True, daemon_running=True)
        output = self._capture_output(report)
        self.assertIn("Deliver daemon: running (pid 12345)", output)

    def test_duplicate_pid_registry_warning_shown(self):
        report = self._make_report(hook_registered=True, daemon_running=True)
        report["registry"]["duplicate_pids"] = [
            {"pid": 12345, "aliases": ["codex", "opencode-c2c-msg"]}
        ]

        output = self._capture_output(report)

        self.assertIn(
            "Duplicate PID 12345: codex, opencode-c2c-msg share the same process",
            output,
        )
        self.assertIn("stale ghost registration", output)

    def test_duplicate_pid_registry_warning_names_likely_stale_aliases(self):
        report = self._make_report(hook_registered=True, daemon_running=True)
        report["registry"]["duplicate_pids"] = [
            {
                "pid": 12345,
                "aliases": ["codex", "opencode-c2c-msg"],
                "likely_stale_aliases": ["opencode-c2c-msg"],
            }
        ]

        output = self._capture_output(report)

        self.assertIn("Likely stale: opencode-c2c-msg", output)

    def test_inactive_stale_inboxes_not_reported_as_nominal(self):
        report = self._make_report(hook_registered=True, daemon_running=True)
        report["stale_inboxes"] = {
            "stale": [],
            "inactive_stale": [
                {
                    "session_id": "proof-session",
                    "alias": "proof-session",
                    "count": 7,
                    "alive": None,
                }
            ],
            "total_pending": 7,
            "inactive_pending": 7,
            "below_threshold_pending": 0,
            "below_threshold_inbox_count": 0,
            "threshold": 5,
        }

        output = self._capture_output(report)

        self.assertIn("Inactive inbox artifacts: 1 session(s)", output)
        self.assertIn("proof-session: 7 pending (inactive)", output)
        self.assertNotIn("nominal", output)

    def test_inactive_stale_output_summarizes_below_threshold_remainder(self):
        report = self._make_report(hook_registered=True, daemon_running=True)
        report["stale_inboxes"] = {
            "stale": [],
            "inactive_stale": [
                {
                    "session_id": "proof-session",
                    "alias": "proof-session",
                    "count": 7,
                    "alive": None,
                }
            ],
            "total_pending": 11,
            "inactive_pending": 7,
            "below_threshold_pending": 4,
            "below_threshold_inbox_count": 2,
            "threshold": 5,
        }

        output = self._capture_output(report)

        self.assertIn("Inactive inbox artifacts: 1 session(s)", output)
        self.assertIn("4 additional message(s) queued below threshold in 2 inbox(es)", output)

    def test_outer_loop_warning_points_to_sweep_dryrun_safe_preview(self):
        report = self._make_report(hook_registered=True, daemon_running=True)
        report["outer_loops"] = {
            "running": [
                {
                    "client": "codex",
                    "pid": 12345,
                    "instance": "codex-local",
                }
            ],
            "safe_to_sweep": False,
        }

        output = self._capture_output(report)

        self.assertIn("Do NOT call c2c sweep", output)
        self.assertIn("c2c sweep-dryrun", output)


class HealthCheckTmpSpaceTests(unittest.TestCase):
    """Tests for c2c_health.check_tmp_space()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health
        self.temp_dir = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_returns_checked_true_on_success(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertTrue(result["checked"])
        self.assertIn("free_bytes", result)
        self.assertIn("free_gb", result)
        self.assertIn("used_pct", result)
        self.assertIn("low", result)

    def test_free_bytes_is_nonnegative(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertGreaterEqual(result["free_bytes"], 0)

    def test_fea_so_files_counted(self):
        # Create fake .fea123.so files
        for i in range(3):
            (self.tmp_dir / f".fea{i}.so").write_bytes(b"x" * 1024)
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertEqual(result["fea_so_count"], 3)
        self.assertGreater(result["fea_so_bytes"], 0)

    def test_no_fea_so_files_returns_zero(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertEqual(result["fea_so_count"], 0)
        self.assertEqual(result["fea_so_bytes"], 0)

    def test_low_flag_set_when_free_below_2gb(self):
        with mock.patch("os.statvfs") as m:
            st = mock.MagicMock()
            # 1 GB total, 500 MB free (below 2 GB threshold)
            st.f_blocks = 256 * 1024  # blocks
            st.f_frsize = 4096  # 4 KB per block → 1 GB total
            st.f_bavail = 128 * 1024  # 512 MB free
            m.return_value = st
            result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertTrue(result["low"])

    def test_low_flag_clear_when_free_above_2gb(self):
        with mock.patch("os.statvfs") as m:
            st = mock.MagicMock()
            # 16 GB total, 8 GB free
            st.f_blocks = 4 * 1024 * 1024  # blocks
            st.f_frsize = 4096  # 4 KB per block → 16 GB total
            st.f_bavail = 2 * 1024 * 1024  # 8 GB free
            m.return_value = st
            result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertFalse(result["low"])

    def test_nonexistent_dir_returns_unchecked(self):
        bad_dir = Path(self.temp_dir.name) / "no-such-dir"
        result = self.c2c_health.check_tmp_space(bad_dir)
        self.assertFalse(result["checked"])
        self.assertIn("error", result)


class HealthCheckInstancesTests(unittest.TestCase):
    """Tests for c2c_health.check_instances()."""

    def setUp(self):
        import c2c_health
        import c2c_start

        self.c2c_health = c2c_health
        self.c2c_start = c2c_start
        self.instances_dir_patcher = mock.patch.object(
            c2c_start,
            "INSTANCES_DIR",
            Path(tempfile.mkdtemp()),
        )
        self.instances_dir = self.instances_dir_patcher.start()

    def tearDown(self):
        self.instances_dir_patcher.stop()
        import shutil

        shutil.rmtree(str(self.c2c_start.INSTANCES_DIR), ignore_errors=True)

    def test_returns_checked_true_and_empty_when_no_instances(self):
        result = self.c2c_health.check_instances()
        self.assertTrue(result["checked"])
        self.assertEqual(result["instances"], [])
        self.assertEqual(result["alive_count"], 0)
        self.assertEqual(result["total_count"], 0)

    def test_alive_count_reflects_live_outer_pids(self):
        # Create two instances — one alive (current pid), one dead (pid 0)
        with mock.patch.object(
            self.c2c_start,
            "run_outer_loop",
            return_value=0,
        ):
            br = Path(tempfile.mkdtemp())
            self.c2c_start.cmd_start("codex", "inst-a", [], br)

        # Patch list_instances so one shows outer_alive=True and one False
        fake = [
            {
                "name": "inst-a",
                "client": "codex",
                "outer_alive": True,
                "outer_pid": os.getpid(),
            },
            {
                "name": "inst-b",
                "client": "kimi",
                "outer_alive": False,
                "outer_pid": None,
            },
        ]
        with mock.patch.object(self.c2c_start, "list_instances", return_value=fake):
            result = self.c2c_health.check_instances()
        self.assertEqual(result["alive_count"], 1)
        self.assertEqual(result["total_count"], 2)

    def test_check_instances_graceful_on_import_error(self):
        with mock.patch.dict("sys.modules", {"c2c_start": None}):
            result = self.c2c_health.check_instances()
        self.assertFalse(result.get("checked", True))

    def test_instances_in_run_health_check_output(self):
        """check_instances result is included in run_health_check() dict."""
        br = Path(tempfile.mkdtemp())
        with mock.patch.object(self.c2c_start, "list_instances", return_value=[]):
            report = self.c2c_health.run_health_check(br)
        self.assertIn("instances", report)
        self.assertTrue(report["instances"]["checked"])


if __name__ == "__main__":
    unittest.main()
