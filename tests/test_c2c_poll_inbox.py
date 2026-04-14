import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_poll_inbox


CLI_TIMEOUT_SECONDS = 5


def run_cli(command, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        [str(REPO / command), *args],
        cwd=REPO,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def result_code(result):
    return result.returncode


class C2CPollInboxTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.words_path = Path(self.temp_dir.name) / "words.txt"
        self.words_path.write_text(
            "storm\nherald\nember\ncrown\nsilver\nbanner\n",
            encoding="utf-8",
        )
        self.env = {
            "C2C_REGISTRY_PATH": str(Path(self.temp_dir.name) / "registry.yaml"),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_c2c_poll_inbox_file_fallback_drains_without_host_mcp_tool(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "codex",
                        "content": "recover without mcp",
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "codex-local",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], "codex-local")
        self.assertEqual(payload["source"], "file")
        self.assertEqual(
            payload["messages"],
            [
                {
                    "from_alias": "storm-echo",
                    "to_alias": "codex",
                    "content": "recover without mcp",
                }
            ],
        )
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_c2c_poll_inbox_defaults_session_from_run_codex_env(self):
        with mock.patch.dict(
            os.environ, {"RUN_CODEX_INST_C2C_SESSION_ID": "codex-from-env"}
        ):
            self.assertEqual(c2c_poll_inbox.resolve_session_id(None), "codex-from-env")

    def test_c2c_poll_inbox_falls_back_to_file_when_direct_mcp_fails(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "codex",
                        "content": "mcp failed but file worked",
                    }
                ]
            ),
            encoding="utf-8",
        )

        with mock.patch(
            "c2c_poll_inbox.call_mcp_tool",
            side_effect=RuntimeError("mcp startup failed"),
        ):
            source, messages = c2c_poll_inbox.poll_inbox(
                broker_root=broker_root,
                session_id="codex-local",
                timeout=0.1,
                force_file=False,
                allow_file_fallback=True,
            )

        self.assertEqual(source, "file")
        self.assertEqual(messages[0]["content"], "mcp failed but file worked")
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_c2c_poll_inbox_times_out_mcp_startup_and_falls_back_to_file(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "codex",
                        "content": "stuck mcp build but file worked",
                    }
                ]
            ),
            encoding="utf-8",
        )

        class StuckProcess:
            pid = 12345

            def communicate(self, _input, timeout=None):
                raise subprocess.TimeoutExpired(["c2c_mcp.py"], timeout)

            def wait(self, timeout=None):
                return 0

        with (
            mock.patch("c2c_poll_inbox.subprocess.Popen", return_value=StuckProcess()),
            mock.patch("c2c_poll_inbox.os.killpg") as killpg,
        ):
            source, messages = c2c_poll_inbox.poll_inbox(
                broker_root=broker_root,
                session_id="codex-local",
                timeout=0.1,
                force_file=False,
                allow_file_fallback=True,
            )

        self.assertEqual(source, "file")
        self.assertEqual(messages[0]["content"], "stuck mcp build but file worked")
        killpg.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_file_fallback_peek_reads_without_draining(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "codex",
                "to_alias": "opencode-local",
                "content": "peek test",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = c2c_poll_inbox.file_fallback_peek(broker_root, "opencode-local")

        self.assertEqual(result, msgs)
        # Inbox must still contain the messages (non-destructive)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_file_fallback_peek_returns_empty_when_no_inbox(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-empty"
        broker_root.mkdir()
        result = c2c_poll_inbox.file_fallback_peek(broker_root, "ghost-session")
        self.assertEqual(result, [])
        # Should NOT create the file (unlike poll which creates it)
        self.assertFalse((broker_root / "ghost-session.inbox.json").exists())

    def test_c2c_poll_inbox_peek_flag_is_nondestructive(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-flag"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "storm-beacon",
                "to_alias": "opencode-local",
                "content": "hello",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "opencode-local",
            "--broker-root",
            str(broker_root),
            "--peek",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["source"], "file-peek")
        self.assertEqual(payload["messages"], msgs)
        # Messages must remain in inbox
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_c2c_peek_inbox_subcommand_is_nondestructive(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-sub"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "codex",
                "to_alias": "opencode-local",
                "content": "subcommand test",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c",
            "peek-inbox",
            "--session-id",
            "opencode-local",
            "--broker-root",
            str(broker_root),
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["source"], "file-peek")
        self.assertEqual(payload["messages"], msgs)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_print_result_count_line_in_text_mode(self):
        """Text-mode output prefixes messages with a count/summary line."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-text"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-count.inbox.json"
        msgs = [
            {"from_alias": "peer-a", "to_alias": "ses-count", "content": "hello"},
            {"from_alias": "peer-b", "to_alias": "ses-count", "content": "world"},
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-count",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        lines = result.stdout.splitlines()
        # First line must be the progress indicator
        self.assertIn("[c2c-poll-inbox]", lines[0])
        self.assertIn("2 messages", lines[0])
        self.assertIn("ses-count", lines[0])
        # Remaining lines are the message envelopes
        self.assertTrue(any('<c2c event="message"' in ln for ln in lines[1:]))

    def test_print_result_singular_message_count_line(self):
        """Single-message drain uses 'message' (not 'messages')."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-singular"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-one.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [{"from_alias": "peer", "to_alias": "ses-one", "content": "hi"}]
            ),
            encoding="utf-8",
        )

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-one",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        first_line = result.stdout.splitlines()[0]
        self.assertIn("1 message", first_line)
        self.assertNotIn("1 messages", first_line)

    def test_print_result_count_field_in_json_mode(self):
        """JSON output includes a top-level 'count' field matching len(messages)."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-json"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-json.inbox.json"
        msgs = [
            {"from_alias": "a", "to_alias": "ses-json", "content": "one"},
            {"from_alias": "b", "to_alias": "ses-json", "content": "two"},
            {"from_alias": "c", "to_alias": "ses-json", "content": "three"},
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-json",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("count", payload)
        self.assertEqual(payload["count"], 3)
        self.assertEqual(len(payload["messages"]), payload["count"])

if __name__ == "__main__":
    unittest.main()
