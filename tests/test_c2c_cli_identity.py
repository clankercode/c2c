import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_whoami
from c2c_registry import save_registry


CLI_TIMEOUT_SECONDS = 5
AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


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


class C2CCLIIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.words_path = Path(self.temp_dir.name) / "words.txt"
        self.words_path.write_text(
            "storm\nherald\nember\ncrown\nsilver\nbanner\n",
            encoding="utf-8",
        )
        self.env = {
            "C2C_REGISTRY_PATH": str(self.registry_path),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }

    def tearDown(self):
        self.temp_dir.cleanup()

    def invoke_cli(self, command, *args, env=None):
        try:
            return run_cli(command, *args, env=env or self.env)
        except FileNotFoundError as error:
            self.fail(f"missing command: {command}\n{error}")

    def test_whoami_json_reports_alias_and_registration_status(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", "--json", env=self.env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "agent-one")
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["registered"], True)
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")
        self.assertIn("tutorial", payload)

    def test_whoami_fails_clearly_for_unregistered_session(self):
        result = self.invoke_cli("c2c-whoami", "agent-one", env=self.env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("session is not registered", result.stderr)

    def test_whoami_without_selector_uses_current_session(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)
        env = dict(self.env)
        env["C2C_SESSION_PID"] = "11111"

        result = self.invoke_cli("c2c-whoami", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["name"], "agent-one")

    def test_whoami_without_selector_uses_parent_shell_claude_child_when_env_missing(
        self,
    ):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                ]
            },
            self.registry_path,
        )

        with (
            mock.patch.dict(os.environ, self.env, clear=False),
            mock.patch("c2c_whoami.current_session_identifier", return_value="11111"),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            result = c2c_whoami.main(["--json"])

        self.assertEqual(result, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["name"], "agent-one")

    def test_whoami_without_selector_fails_when_not_uniquely_resolvable(self):
        stderr = io.StringIO()

        with (
            mock.patch.dict(os.environ, self.env, clear=False),
            mock.patch(
                "c2c_whoami.current_session_identifier",
                side_effect=ValueError(
                    "could not resolve current session uniquely; use a session ID or PID"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_whoami.main([])

        self.assertEqual(result, 1)
        self.assertIn("could not resolve current session uniquely", stderr.getvalue())
        self.assertIn("session ID or PID", stderr.getvalue())

    def test_whoami_human_output_includes_tutorial(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", env=self.env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("Alias:", result.stdout)
        self.assertIn("Session: agent-one", result.stdout)
        self.assertIn(f"Session ID: {AGENT_ONE_SESSION_ID}", result.stdout)
        self.assertIn("Registered: yes", result.stdout)
        self.assertIn("What is C2C?", result.stdout)
        self.assertIn("c2c-send <alias> <message...>", result.stdout)
        self.assertIn("If Bash approval allows it, reply with c2c-send", result.stdout)
        self.assertIn(
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            result.stdout,
        )

    def test_register_rejects_ambiguous_session_name(self):
        ambiguous_env = dict(self.env)
        ambiguous_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-ambiguous-name.json"
        )

        result = self.invoke_cli("c2c-register", "shared-agent", env=ambiguous_env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("ambiguous session name", result.stderr)
        self.assertIn("session ID or PID", result.stderr)

    def test_register_fails_fast_for_invalid_sessions_fixture(self):
        invalid_env = dict(self.env)
        invalid_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-invalid.json"
        )

        result = self.invoke_cli("c2c-register", "agent-one", env=invalid_env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("invalid sessions fixture", result.stderr)

    def test_send_resolves_alias_to_live_session(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-two", "--json", env=self.env
        )
        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]
        sent = self.invoke_cli(
            "c2c-send",
            alias,
            "hello",
            "peer",
            "--dry-run",
            "--json",
        )
        self.assertEqual(result_code(sent), 0)
        payload = json.loads(sent.stdout)
        self.assertEqual(payload["resolved_alias"], alias)
        self.assertEqual(
            payload["to_session_id"], "fa68bd5b-0529-4292-bc27-d617f6840ce7"
        )

    def test_send_fails_clearly_for_unknown_alias(self):
        result = self.invoke_cli("c2c-send", "unknown-alias", "hello")

        self.assertEqual(result_code(result), 1)
        self.assertIn("unknown alias", result.stderr)
        self.assertIn("unknown-alias", result.stderr)

    def test_send_dry_run_resolves_broker_only_alias(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)

        result = self.invoke_cli(
            "c2c-send", "codex", "hello", "peer", "--dry-run", "--json", env=env
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["resolved_alias"], "codex")
        self.assertEqual(payload["to"], "broker:codex-local")
        self.assertEqual(payload["to_session_id"], "codex-local")

    def test_verify_supports_fixture_based_json_output(self):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                ]
            },
            self.registry_path,
        )
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")
        result = self.invoke_cli("c2c-verify", "--json", env=verify_env)
        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload,
            {
                "goal_met": False,
                "participants": {
                    "agent-one": {"received": 1, "sent": 1},
                    "agent-two": {"received": 1, "sent": 1},
                },
            },
        )

    def test_verify_human_output_reports_progress_per_participant(self):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                ]
            },
            self.registry_path,
        )
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")

        result = self.invoke_cli("c2c-verify", env=verify_env)

        self.assertEqual(result_code(result), 0)
        self.assertEqual(
            result.stdout.strip().splitlines(),
            [
                "agent-one: sent=1 received=1 status=in_progress",
                "agent-two: sent=1 received=1 status=in_progress",
                "goal_met: no",
            ],
        )

if __name__ == "__main__":
    unittest.main()
