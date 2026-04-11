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

import c2c_register
import c2c_registry
import c2c_send
import c2c_verify
import c2c_whoami
import claude_list_sessions
import claude_send_msg
from c2c_list import list_registered_sessions
from c2c_register import register_session
from c2c_registry import load_registry, save_registry


CLI_TIMEOUT_SECONDS = 5
AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


def run_cli(command, *args, env=None):
    return run_cli_in_root(REPO, command, *args, env=env)


def run_cli_in_root(root, command, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        [str(Path(root) / command), *args],
        cwd=root,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def copy_cli_checkout(source_root: Path, target_root: Path) -> None:
    target_root.mkdir(parents=True, exist_ok=True)
    source_git_path = source_root / ".git"
    target_git_path = target_root / ".git"
    if source_git_path.is_dir():
        shutil.copytree(source_git_path, target_git_path)
    else:
        shutil.copy2(source_git_path, target_git_path)
    for relative_path in [
        "c2c-register",
        "c2c-list",
        "c2c_register.py",
        "c2c_list.py",
        "c2c_registry.py",
        "claude_send_msg.py",
        "claude_list_sessions.py",
    ]:
        shutil.copy2(source_root / relative_path, target_root / relative_path)


class C2CCLITests(unittest.TestCase):
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
        }

    def tearDown(self):
        self.temp_dir.cleanup()

    def invoke_cli(self, command, *args, env=None):
        try:
            return run_cli(command, *args, env=env or self.env)
        except FileNotFoundError as error:
            self.fail(f"missing command: {command}\n{error}")

    def test_register_returns_alias_and_json(self):
        result = self.invoke_cli(
            "c2c-register",
            "6e45bbe8-998c-4140-b77e-c6f117e6ca4b",
            "--json",
        )
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], "6e45bbe8-998c-4140-b77e-c6f117e6ca4b")
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")

    def test_register_is_idempotent_for_same_live_session(self):
        first = self.invoke_cli("c2c-register", "agent-one", "--json")
        second = self.invoke_cli("c2c-register", "agent-one", "--json")
        self.assertEqual(result_code(first), 0)
        self.assertEqual(result_code(second), 0)
        self.assertEqual(
            json.loads(first.stdout)["alias"], json.loads(second.stdout)["alias"]
        )

    def test_register_persists_yaml_registry_record(self):
        result = self.invoke_cli("c2c-register", AGENT_ONE_SESSION_ID, "--json")
        self.assertEqual(result_code(result), 0)
        self.assertTrue(self.registry_path.exists())
        registry_text = self.registry_path.read_text(encoding="utf-8")
        self.assertIn("registrations:", registry_text)
        self.assertIn(f"session_id: {AGENT_ONE_SESSION_ID}", registry_text)
        self.assertRegex(registry_text, r"alias: [a-z]+-[a-z]+")

    def test_list_only_shows_opted_in_sessions(self):
        registered = self.invoke_cli("c2c-register", "agent-one", env=self.env)
        self.assertEqual(result_code(registered), 0)
        listed = self.invoke_cli("c2c-list", "--json", env=self.env)
        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual([item["name"] for item in payload["sessions"]], ["agent-one"])

    def test_list_prunes_dead_registrations(self):
        registered = self.invoke_cli("c2c-register", "agent-one", env=self.env)
        self.assertEqual(result_code(registered), 0)
        dead_env = dict(self.env)
        dead_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-live-and-dead.json"
        )
        listed = self.invoke_cli("c2c-list", "--json", env=dead_env)
        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(payload["sessions"], [])

    def test_list_returns_recently_registered_sessions_in_same_environment(self):
        register_checkout = Path(self.temp_dir.name) / "checkout-register"
        list_checkout = Path(self.temp_dir.name) / "checkout-list"
        copy_cli_checkout(REPO, register_checkout)
        copy_cli_checkout(REPO, list_checkout)

        env = {
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
        }

        first = run_cli_in_root(
            register_checkout, "c2c-register", "agent-one", "--json", env=env
        )
        second = run_cli_in_root(
            register_checkout, "c2c-register", "agent-two", "--json", env=env
        )

        self.assertEqual(result_code(first), 0)
        self.assertEqual(result_code(second), 0)

        listed = run_cli_in_root(list_checkout, "c2c-list", "--json", env=env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            sorted(item["session_id"] for item in payload["sessions"]),
            [AGENT_ONE_SESSION_ID, AGENT_TWO_SESSION_ID],
        )

    def test_install_writes_user_local_wrappers(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)

        result = self.invoke_cli("c2c-install", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(
            sorted(payload["installed_commands"]),
            [
                "c2c-install",
                "c2c-list",
                "c2c-register",
                "c2c-send",
                "c2c-verify",
                "c2c-whoami",
            ],
        )
        self.assertTrue((install_dir / "c2c-register").exists())
        self.assertTrue((install_dir / "c2c-whoami").exists())

    def test_install_reports_path_guidance_when_bin_not_on_path(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)
        env["PATH"] = "/usr/bin"

        result = self.invoke_cli("c2c-install", env=env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("not currently on PATH", result.stdout)

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
        result = self.invoke_cli("c2c-whoami", env=self.env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("could not resolve current session uniquely", result.stderr)
        self.assertIn("session ID or PID", result.stderr)

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


class C2CRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_default_registry_path_uses_shared_git_state_location(self):
        common_dir = Path(self.temp_dir.name) / "repo" / ".git"
        expected = common_dir / "c2c" / "registry.yaml"

        with mock.patch("c2c_registry.repo_common_dir", return_value=common_dir):
            self.assertEqual(c2c_registry.default_registry_path(), expected)

    def test_load_registry_reads_minimal_yaml_format(self):
        self.registry_path.write_text(
            "registrations:\n"
            "  - session_id: 6e45bbe8-998c-4140-b77e-c6f117e6ca4b\n"
            "    alias: storm-herald\n",
            encoding="utf-8",
        )

        self.assertEqual(
            load_registry(self.registry_path),
            {
                "registrations": [
                    {
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-herald",
                    }
                ]
            },
        )

    def test_save_registry_replaces_file_atomically(self):
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        with mock.patch("c2c_registry.os.replace", wraps=os.replace) as replace_mock:
            save_registry(registry, self.registry_path)

        self.assertEqual(replace_mock.call_count, 1)
        self.assertEqual(replace_mock.call_args.args[1], self.registry_path)

    def test_registry_round_trips_quoted_yaml_scalars(self):
        registry = {
            "registrations": [
                {
                    "session_id": 'agent "one" \\ path',
                    "alias": 'signal "flare" \\ relay',
                }
            ]
        }

        save_registry(registry, self.registry_path)

        self.assertEqual(load_registry(self.registry_path), registry)


class C2CRegisterUnitTests(unittest.TestCase):
    def test_register_session_uses_transactional_registry_update(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch(
                "c2c_register.update_registry", return_value=registration
            ) as update,
        ):
            (
                resolved_session,
                resolved_registration,
                registration_was_new,
            ) = register_session("agent-one")

        self.assertEqual(resolved_session, session)
        self.assertEqual(resolved_registration, registration)
        self.assertFalse(registration_was_new)
        self.assertEqual(update.call_count, 1)

    def test_register_session_does_not_load_alias_words_for_existing_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        def mutate_registry(mutator):
            return mutator(registry)

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch("c2c_register.update_registry", side_effect=mutate_registry),
            mock.patch("c2c_register.load_alias_words") as load_alias_words,
        ):
            (
                resolved_session,
                resolved_registration,
                registration_was_new,
            ) = register_session("agent-one")

        self.assertEqual(resolved_session, session)
        self.assertEqual(resolved_registration, registry["registrations"][0])
        self.assertFalse(registration_was_new)
        load_alias_words.assert_not_called()


class C2CRegisterNotificationTests(unittest.TestCase):
    def test_register_sends_onboarding_for_new_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session"
            ) as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_called_once_with(
            session,
            "You are now registered for C2C.\n"
            "Your alias is storm-herald.\n"
            "Run c2c-whoami for your current details and tutorial.\n"
            "Run c2c-list to see other opted-in sessions.\n"
            "Use c2c-send <alias> <message...> to talk to a peer.",
            tag="onboarding",
        )

    def test_register_sends_onboarding_with_non_c2c_tag(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with mock.patch(
            "c2c_register.claude_send_msg.send_message_to_session"
        ) as send_message:
            c2c_register.send_onboarding_message(session, "storm-herald")

        send_message.assert_called_once_with(
            session,
            "You are now registered for C2C.\n"
            "Your alias is storm-herald.\n"
            "Run c2c-whoami for your current details and tutorial.\n"
            "Run c2c-list to see other opted-in sessions.\n"
            "Use c2c-send <alias> <message...> to talk to a peer.",
            tag="onboarding",
        )

    def test_register_does_not_resend_onboarding_for_existing_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, False),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session"
            ) as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_not_called()

    def test_register_returns_non_zero_when_new_registration_onboarding_send_fails(
        self,
    ):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
        stderr = io.StringIO()

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session",
                side_effect=RuntimeError("target session has no pts tty"),
            ),
            mock.patch("c2c_register.rollback_registration") as rollback_registration,
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 1)
        rollback_registration.assert_called_once_with(
            AGENT_ONE_SESSION_ID, "storm-herald"
        )
        self.assertEqual(stderr.getvalue().strip(), "target session has no pts tty")

    def test_register_rolls_back_new_registration_when_onboarding_send_fails(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            words_path = Path(temp_dir) / "words.txt"
            words_path.write_text(
                "storm\nherald\nember\ncrown\nsilver\nbanner\n",
                encoding="utf-8",
            )

            with (
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(registry_path),
                        "C2C_ALIAS_WORDS_PATH": str(words_path),
                    },
                    clear=False,
                ),
                mock.patch("c2c_register.load_sessions", return_value=[session]),
                mock.patch(
                    "c2c_register.claude_send_msg.send_message_to_session",
                    side_effect=RuntimeError("target session has no pts tty"),
                ),
                mock.patch("sys.stderr", io.StringIO()),
            ):
                result = c2c_register.main(["agent-one"])

            self.assertEqual(result, 1)
            self.assertEqual(load_registry(registry_path)["registrations"], [])

    def test_register_rolls_back_new_registration_when_onboarding_send_raises_unexpected_exception(
        self,
    ):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
        stderr = io.StringIO()

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session",
                side_effect=ValueError("unexpected onboarding failure"),
            ),
            mock.patch("c2c_register.rollback_registration") as rollback_registration,
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 1)
        rollback_registration.assert_called_once_with(
            AGENT_ONE_SESSION_ID, "storm-herald"
        )
        self.assertEqual(stderr.getvalue().strip(), "unexpected onboarding failure")

    def test_rollback_registration_only_removes_matching_alias(self):
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "ember-crown"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "silver-banner"},
            ]
        }

        def mutate_registry(mutator):
            mutator(registry)

        with mock.patch("c2c_register.update_registry", side_effect=mutate_registry):
            c2c_register.rollback_registration(AGENT_ONE_SESSION_ID, "storm-herald")

        self.assertEqual(
            registry["registrations"],
            [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "ember-crown"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "silver-banner"},
            ],
        )


class C2CTestHelpersTests(unittest.TestCase):
    def test_copy_cli_checkout_supports_git_directory_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source_root = Path(temp_dir) / "source"
            target_root = Path(temp_dir) / "target"
            source_root.mkdir()
            (source_root / ".git").mkdir()
            (source_root / ".git" / "HEAD").write_text(
                "ref: refs/heads/main\n", encoding="utf-8"
            )

            for relative_path in [
                "c2c-register",
                "c2c-list",
                "c2c_register.py",
                "c2c_list.py",
                "c2c_registry.py",
                "claude_send_msg.py",
                "claude_list_sessions.py",
            ]:
                (source_root / relative_path).write_text(
                    "placeholder\n", encoding="utf-8"
                )

            copy_cli_checkout(source_root, target_root)

            self.assertTrue((target_root / ".git").is_dir())
            self.assertEqual(
                (target_root / ".git" / "HEAD").read_text(encoding="utf-8"),
                "ref: refs/heads/main\n",
            )


class C2CListUnitTests(unittest.TestCase):
    def test_list_registered_sessions_uses_transactional_registry_update(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": session["session_id"], "alias": "ember-crown"},
            ]
        }

        def mutate_registry(mutator):
            mutator(registry)
            return registry

        with (
            mock.patch("c2c_list.load_sessions", return_value=[session]),
            mock.patch(
                "c2c_list.update_registry", side_effect=mutate_registry
            ) as update,
        ):
            rows = list_registered_sessions()

        self.assertEqual(
            rows,
            [
                {
                    "alias": "ember-crown",
                    "name": "agent-two",
                    "session_id": session["session_id"],
                }
            ],
        )
        self.assertEqual(update.call_count, 1)


class C2CSendUnitTests(unittest.TestCase):
    def test_send_to_alias_delegates_to_existing_send_surface(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        registration = {"session_id": session["session_id"], "alias": "ember-crown"}
        delegated_result = {
            "ok": True,
            "to": "agent-two",
            "session_id": session["session_id"],
            "pid": 11112,
            "sent_at": 123.0,
        }

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value=delegated_result,
            ) as delegate,
        ):
            result = c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        self.assertEqual(result, delegated_result)
        delegate.assert_called_once_with(session, "hello peer")

    def test_main_reports_send_surface_failures_cleanly(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        registration = {"session_id": session["session_id"], "alias": "ember-crown"}
        stderr = io.StringIO()

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.delegate_send",
                side_effect=subprocess.CalledProcessError(
                    1, ["pty_inject"], stderr="permission denied\n"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_send.main(["ember-crown", "hello"])

        self.assertEqual(result, 1)
        self.assertEqual(stderr.getvalue().strip(), "send failed: permission denied")

    def test_main_uses_human_output_without_json_flag(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_send.send_to_alias",
                return_value={
                    "ok": True,
                    "to": "agent-two",
                    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
                    "pid": 11112,
                    "sent_at": 123.0,
                },
            ),
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_send.main(["ember-crown", "hello"])

        self.assertEqual(result, 0)
        self.assertEqual(
            stdout.getvalue().strip(), "Sent c2c message to agent-two (ember-crown)"
        )


class ClaudeListSessionsUnitTests(unittest.TestCase):
    def test_load_sessions_defaults_to_fast_mode_without_terminal_owner_lookup(self):
        session_file = Path("/tmp/session.json")
        session_data = {
            "name": "agent-one",
            "pid": 11111,
            "sessionId": AGENT_ONE_SESSION_ID,
            "cwd": "/tmp/project",
        }

        with (
            mock.patch("claude_list_sessions.fixture_path_from_env", return_value=None),
            mock.patch(
                "claude_list_sessions.iter_session_files",
                return_value=[(".claude", session_file)],
            ),
            mock.patch("claude_list_sessions.safe_json", return_value=session_data),
            mock.patch("claude_list_sessions.process_alive", return_value=True),
            mock.patch("claude_list_sessions.readlink", return_value="/dev/pts/12"),
            mock.patch(
                "claude_list_sessions.find_terminal_owner",
                side_effect=AssertionError(
                    "find_terminal_owner should not run in fast mode"
                ),
            ),
        ):
            rows = claude_list_sessions.load_sessions()

        self.assertEqual(
            rows,
            [
                {
                    "profile": ".claude",
                    "name": "agent-one",
                    "pid": 11111,
                    "session_id": AGENT_ONE_SESSION_ID,
                    "cwd": "/tmp/project",
                    "tty": "/dev/pts/12",
                    "terminal_pid": "",
                    "terminal_master_fd": "",
                    "transcript": claude_list_sessions.transcript_path(
                        "/tmp/project", AGENT_ONE_SESSION_ID
                    )
                    or "",
                }
            ],
        )

    def test_load_sessions_with_terminal_owner_populates_owner_fields(self):
        session_file = Path("/tmp/session.json")
        session_data = {
            "name": "agent-one",
            "pid": 11111,
            "sessionId": AGENT_ONE_SESSION_ID,
            "cwd": "/tmp/project",
        }

        with (
            mock.patch("claude_list_sessions.fixture_path_from_env", return_value=None),
            mock.patch(
                "claude_list_sessions.iter_session_files",
                return_value=[(".claude", session_file)],
            ),
            mock.patch("claude_list_sessions.safe_json", return_value=session_data),
            mock.patch("claude_list_sessions.process_alive", return_value=True),
            mock.patch("claude_list_sessions.readlink", return_value="/dev/pts/12"),
            mock.patch(
                "claude_list_sessions.find_terminal_owner", return_value=(22222, 7)
            ) as find_owner,
        ):
            rows = claude_list_sessions.load_sessions(with_terminal_owner=True)

        self.assertEqual(find_owner.call_count, 1)
        self.assertEqual(rows[0]["terminal_pid"], 22222)
        self.assertEqual(rows[0]["terminal_master_fd"], 7)

    def test_find_terminal_owner_uses_parent_chain_before_global_scan(self):
        with (
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_parent_chain",
                return_value=(22222, 7),
            ) as parent_chain_lookup,
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_proc_scan",
                side_effect=AssertionError(
                    "global proc scan should not run when parent-chain lookup succeeds"
                ),
            ) as global_scan,
        ):
            owner = claude_list_sessions.find_terminal_owner("12", session_pid=11111)

        self.assertEqual(owner, (22222, 7))
        parent_chain_lookup.assert_called_once_with(11111, "12")
        global_scan.assert_not_called()

    def test_find_terminal_owner_falls_back_to_global_scan_when_parent_chain_misses(
        self,
    ):
        with (
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_parent_chain",
                return_value=(None, None),
            ) as parent_chain_lookup,
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_proc_scan",
                return_value=(33333, 8),
            ) as global_scan,
        ):
            owner = claude_list_sessions.find_terminal_owner("12", session_pid=11111)

        self.assertEqual(owner, (33333, 8))
        parent_chain_lookup.assert_called_once_with(11111, "12")
        global_scan.assert_called_once_with("12")


class ClaudeSendMsgUnitTests(unittest.TestCase):
    def test_send_message_to_session_reloads_full_terminal_metadata_when_needed(self):
        partial_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        full_session = {
            **partial_session,
            "terminal_pid": 33333,
            "terminal_master_fd": 8,
        }

        with (
            mock.patch("claude_send_msg.use_send_message_fixture", return_value=False),
            mock.patch(
                "claude_send_msg.load_sessions", return_value=[full_session]
            ) as load_sessions,
            mock.patch("claude_send_msg.inject") as inject,
            mock.patch("claude_send_msg.time.time", return_value=123.0),
        ):
            result = claude_send_msg.send_message_to_session(
                partial_session, "hello peer"
            )

        load_sessions.assert_called_once_with()
        inject.assert_called_once_with(
            full_session, "<c2c-message>\nhello peer\n</c2c-message>"
        )
        self.assertEqual(
            result,
            {
                "ok": True,
                "to": "agent-two",
                "session_id": AGENT_TWO_SESSION_ID,
                "pid": 11112,
                "sent_at": 123.0,
            },
        )


class C2CVerifyUnitTests(unittest.TestCase):
    def test_resolve_transcript_path_prefers_sessions_fixture_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "fixtures" / "sessions-live.json"
            fixture_path.parent.mkdir(parents=True)
            transcript_path = fixture_path.parent / "nested" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with tempfile.TemporaryDirectory() as other_dir:
                with (
                    mock.patch.dict(
                        os.environ,
                        {"C2C_SESSIONS_FIXTURE": str(fixture_path)},
                        clear=False,
                    ),
                    mock.patch("os.getcwd", return_value=other_dir),
                ):
                    resolved = c2c_verify.resolve_transcript_path(
                        "nested/transcript.jsonl"
                    )

        self.assertEqual(resolved, transcript_path)

    def test_resolve_transcript_path_preserves_relative_structure_under_fixture_root(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_root = Path(temp_dir)
            transcript_path = fixture_root / "nested" / "history" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with mock.patch.dict(
                os.environ, {"C2C_VERIFY_FIXTURE": str(fixture_root)}, clear=False
            ):
                resolved = c2c_verify.resolve_transcript_path(
                    "nested/history/transcript.jsonl"
                )

        self.assertEqual(resolved, transcript_path)

    def test_verify_progress_disambiguates_duplicate_participant_names(self):
        sessions = [
            {"name": "shared-agent", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "shared-agent", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 4, "received": 5},
                    ],
                ),
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"],
            {
                "shared-agent (11111111)": {"sent": 2, "received": 3},
                "shared-agent (22222222)": {"sent": 4, "received": 5},
            },
        )

    def test_verify_progress_sets_goal_met_only_when_all_participants_meet_threshold(
        self,
    ):
        sessions = [
            {"name": "agent-one", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "agent-two", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 19, "received": 20},
                    ],
                ),
            ):
                met_payload = c2c_verify.verify_progress()
                not_met_payload = c2c_verify.verify_progress()

        self.assertTrue(met_payload["goal_met"])
        self.assertFalse(not_met_payload["goal_met"])

    def test_verify_progress_ignores_unregistered_live_sessions(self):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {
                "name": "agent-two",
                "session_id": AGENT_TWO_SESSION_ID,
                "transcript": "b",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 99, "received": 99},
                    ],
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 2, "received": 3}}
        )
        summarize.assert_called_once_with("a")

    def test_verify_progress_ignores_missing_transcript_when_session_not_registered(
        self,
    ):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    return_value={"sent": 1, "received": 4},
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 1, "received": 4}}
        )
        summarize.assert_called_once_with("a")

    def test_summarize_transcript_counts_queued_replies(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c-message>one</c2c-message>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c-message>two</c2c-message>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply one"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply two"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 2, "received": 2},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CWhoamiUnitTests(unittest.TestCase):
    def test_current_session_identifier_uses_single_claude_child_of_parent_shell(self):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [(11111, "claude")], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "11111")

    def test_current_session_identifier_fails_when_parent_chain_has_multiple_claude_children(
        self,
    ):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                return_value=[(11111, "claude"), (22222, "claude")],
            ),
        ):
            with self.assertRaisesRegex(
                ValueError, "could not resolve current session uniquely"
            ):
                c2c_whoami.current_session_identifier()

    def test_summarize_transcript_does_not_count_assistant_after_unrelated_user_turn(
        self,
    ):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c-message>one</c2c-message>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"follow-up outside c2c"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"general reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 0, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)

    def test_summarize_transcript_counts_reply_after_tool_use_and_tool_result(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c-message>one</c2c-message>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"lookup","input":{}}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply after tool"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
