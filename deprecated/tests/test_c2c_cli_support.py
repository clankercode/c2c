import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_mcp
import c2c_registry


class BuildRegistrationRecordTests(unittest.TestCase):
    def test_includes_pid_fields_when_passed(self):
        record = c2c_registry.build_registration_record(
            "sess-1", "storm-herald", pid=42, pid_start_time=99999
        )
        self.assertEqual(record["session_id"], "sess-1")
        self.assertEqual(record["alias"], "storm-herald")
        self.assertEqual(record["pid"], 42)
        self.assertEqual(record["pid_start_time"], 99999)

    def test_omits_pid_fields_when_not_passed(self):
        record = c2c_registry.build_registration_record("sess-1", "storm-herald")
        self.assertEqual(record, {"session_id": "sess-1", "alias": "storm-herald"})
        self.assertNotIn("pid", record)
        self.assertNotIn("pid_start_time", record)


class MergeBrokerRegistrationTests(unittest.TestCase):
    def test_carries_pid_fields_through_from_source(self):
        source = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        merged = c2c_mcp.merge_broker_registration(None, source)
        self.assertEqual(merged["pid"], 42)
        self.assertEqual(merged["pid_start_time"], 99999)

    def test_preserves_existing_pid_fields_when_source_has_none(self):
        existing = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        source = {"session_id": "sess-1", "alias": "storm-herald"}
        merged = c2c_mcp.merge_broker_registration(existing, source)
        self.assertEqual(merged["pid"], 42)
        self.assertEqual(merged["pid_start_time"], 99999)

    def test_source_pid_overwrites_existing(self):
        """YAML pid (refreshed on each register) takes precedence over stale broker pid."""
        existing = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        source = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 100,
            "pid_start_time": 55555,
        }
        merged = c2c_mcp.merge_broker_registration(existing, source)
        self.assertEqual(merged["pid"], 100)
        self.assertEqual(merged["pid_start_time"], 55555)

    def test_pidless_new_entry_has_no_pid_fields(self):
        """New entry from pidless YAML should not fabricate pid fields."""
        source = {"session_id": "sess-1", "alias": "storm-herald"}
        merged = c2c_mcp.merge_broker_registration(None, source)
        self.assertNotIn("pid", merged)
        self.assertNotIn("pid_start_time", merged)


class SyncBrokerRegistryPidTests(unittest.TestCase):
    """Integration: sync_broker_registry preserves pid fields correctly."""

    def test_yaml_entry_with_pid_syncs_pid_to_broker(self):
        """YAML entries with pid populate the broker entry's pid fields."""
        with tempfile.TemporaryDirectory() as tmpdir:
            broker_root = Path(tmpdir) / "broker"
            broker_root.mkdir()
            yaml_path = Path(tmpdir) / "registry.yaml"
            yaml_path.write_text(
                "registrations:\n"
                "  - session_id: live-session\n"
                "    alias: storm-live\n"
                "    pid: 42\n"
                "    pid_start_time: 99999\n",
                encoding="utf-8",
            )
            with mock.patch("c2c_mcp.registry_path_from_env", return_value=yaml_path):
                c2c_mcp.sync_broker_registry(broker_root)

            data = json.loads(
                (broker_root / "registry.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["pid"], 42)
            self.assertEqual(data[0]["pid_start_time"], 99999)

    def test_broker_pid_preserved_when_yaml_has_no_pid(self):
        """When broker already has a pid-bearing entry, sync preserves it."""
        with tempfile.TemporaryDirectory() as tmpdir:
            broker_root = Path(tmpdir) / "broker"
            broker_root.mkdir()
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "live-session",
                            "alias": "storm-live",
                            "pid": 12345,
                            "pid_start_time": 99999,
                        }
                    ]
                ),
                encoding="utf-8",
            )
            yaml_path = Path(tmpdir) / "registry.yaml"
            yaml_path.write_text(
                "registrations:\n  - session_id: live-session\n    alias: storm-live\n",
                encoding="utf-8",
            )
            with mock.patch("c2c_mcp.registry_path_from_env", return_value=yaml_path):
                c2c_mcp.sync_broker_registry(broker_root)

            data = json.loads(
                (broker_root / "registry.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["pid"], 12345)
            self.assertEqual(data[0]["pid_start_time"], 99999)


class RestartMeUnitTests(unittest.TestCase):
    """Unit tests for c2c_restart_me helper functions."""

    def test_build_restart_argv_claude_code_with_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code",
            "abc-123",
            ["/usr/bin/claude", "--dangerously-skip-permissions"],
        )
        self.assertEqual(result[0], "/usr/bin/claude")
        self.assertIn("--resume", result)
        idx = result.index("--resume")
        self.assertEqual(result[idx + 1], "abc-123")
        self.assertIn("--dangerously-skip-permissions", result)

    def test_build_restart_argv_claude_code_no_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code", None, ["/usr/bin/claude"]
        )
        self.assertEqual(result, ["/usr/bin/claude"])
        self.assertNotIn("--resume", result)

    def test_build_restart_argv_claude_code_skips_prior_resume(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code",
            "new-uuid",
            ["/usr/bin/claude", "--resume", "old-uuid"],
        )
        self.assertIn("--resume", result)
        idx = result.index("--resume")
        self.assertEqual(result[idx + 1], "new-uuid")
        # old-uuid should not appear
        self.assertNotIn("old-uuid", result)

    def test_build_restart_argv_codex(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "codex", None, ["/usr/local/bin/codex", "--some-flag"]
        )
        self.assertEqual(result, ["/usr/local/bin/codex"])

    def test_build_restart_argv_opencode(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "opencode", None, ["/usr/local/bin/opencode"]
        )
        self.assertEqual(result, ["/usr/local/bin/opencode"])

    def test_uuid_from_cmdline_extracts_resume_arg(self):
        import c2c_restart_me

        cmdline = ["claude", "--resume", "abc-def-123-456-7890"]
        result = c2c_restart_me._uuid_from_cmdline(cmdline)
        self.assertEqual(result, "abc-def-123-456-7890")

    def test_uuid_from_cmdline_returns_none_without_resume(self):
        import c2c_restart_me

        result = c2c_restart_me._uuid_from_cmdline(["claude", "--some-flag"])
        self.assertIsNone(result)

    def test_uuid_from_cmdline_returns_none_for_non_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me._uuid_from_cmdline(["claude", "--resume", "notauuid"])
        self.assertIsNone(result)

    def test_uuid_from_claude_dir_returns_newest_jsonl_stem(self):
        import c2c_restart_me

        with tempfile.TemporaryDirectory() as tmp:
            slug = "home-user-src-repo"
            proj_dir = Path(tmp) / ".claude" / "projects" / slug
            proj_dir.mkdir(parents=True)
            old_file = proj_dir / "old-uuid-1111.jsonl"
            new_file = proj_dir / "new-uuid-2222.jsonl"
            old_file.write_text("[]", encoding="utf-8")
            import time as _time

            _time.sleep(0.01)
            new_file.write_text("[]", encoding="utf-8")

            # Point the function at our temp dir by monkeypatching Path.home()
            with mock.patch("c2c_restart_me.Path.home", return_value=Path(tmp)):
                # Need a fake /proc/<pid>/cwd symlink pointing at our dir
                # Instead call _uuid_from_claude_dir directly with a real pid
                # by patching os.readlink
                cwd = f"/home/user/src/repo"
                with mock.patch("os.readlink", return_value=cwd):
                    result = c2c_restart_me._uuid_from_claude_dir(12345)

            self.assertEqual(result, "new-uuid-2222")

    def test_print_unmanaged_instructions_includes_resume(self):
        import c2c_restart_me
        import io
        from unittest.mock import patch

        with patch("sys.stdout", new_callable=io.StringIO) as mock_out:
            c2c_restart_me.print_unmanaged_instructions("claude-code")
            output = mock_out.getvalue()

        self.assertIn("claude --resume", output)
        self.assertIn("/exit", output)


if __name__ == "__main__":
    unittest.main()
