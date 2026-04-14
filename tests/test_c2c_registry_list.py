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
from c2c_list import list_registered_sessions, list_sessions
from c2c_register import register_session
from c2c_registry import load_registry, save_registry


AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


def copy_cli_checkout(source_root: Path, target_root: Path) -> None:
    target_root.mkdir(parents=True, exist_ok=True)
    source_git_path = source_root / ".git"
    target_git_path = target_root / ".git"
    if source_git_path.is_dir():
        # Exclude large subdirs that tests don't need:
        #   c2c/    — live broker data (tests use C2C_REGISTRY_PATH instead)
        #   objects/ — git object pack (only HEAD/config/refs needed for rev-parse)
        #   logs/    — reflog not needed
        # Copying the full .git (30+ MB objects + broker archives) exhausts /tmp
        # per-user disk quota on CI machines.
        shutil.copytree(
            source_git_path,
            target_git_path,
            ignore=shutil.ignore_patterns("c2c", "objects", "logs", "rr-cache"),
        )
    else:
        shutil.copy2(source_git_path, target_git_path)
    for relative_path in [
        "c2c",
        "c2c-broker-gc",
        "c2c-claude-wake",
        "c2c-configure-claude-code",
        "c2c-configure-codex",
        "c2c-configure-crush",
        "c2c-configure-kimi",
        "c2c-configure-opencode",
        "c2c-crush-wake",
        "c2c-deliver-inbox",
        "c2c-health",
        "c2c-init",
        "c2c-kimi-wake",
        "c2c-kimi-wire-bridge",
        "c2c-opencode-wake",
        "c2c-prune",
        "c2c-register",
        "c2c-restart-me",
        "c2c-room",
        "c2c-list",
        "c2c-send",
        "c2c-send-all",
        "c2c-setup",
        "c2c-install",
        "c2c-inject",
        "c2c-poker-sweep",
        "c2c-verify",
        "c2c-watch",
        "c2c-whoami",
        "restart-codex-self",
        "restart-crush-self",
        "restart-kimi-self",
        "restart-opencode-self",
        "run-crush-inst",
        "run-crush-inst-outer",
        "run-crush-inst-rearm",
        "run-kimi-inst",
        "run-kimi-inst-outer",
        "run-kimi-inst-rearm",
        "c2c_kimi_prefill.py",
        "c2c_broker_gc.py",
        "c2c_dead_letter.py",
        "c2c_register.py",
        "c2c_restart_me.py",
        "c2c_room.py",
        "c2c_configure_claude_code.py",
        "c2c_configure_codex.py",
        "c2c_configure_crush.py",
        "c2c_configure_kimi.py",
        "c2c_configure_opencode.py",
        "c2c_init.py",
        "c2c_list.py",
        "c2c_prune.py",
        "c2c_send.py",
        "c2c_send_all.py",
        "c2c_smoke_test.py",
        "c2c_setup.py",
        "c2c_install.py",
        "c2c_deliver_inbox.py",
        "c2c_inject.py",
        "c2c_poker.py",
        "c2c_poker_sweep.py",
        "c2c_poll_inbox.py",
        "c2c_pts_inject.py",
        "c2c_verify.py",
        "c2c_watch.py",
        "c2c_whoami.py",
        "c2c_health.py",
        "c2c_claude_wake_daemon.py",
        "c2c_kimi_wake_daemon.py",
        "c2c_kimi_wire_bridge.py",
        "c2c_opencode_wake_daemon.py",
        "c2c_crush_wake_daemon.py",
        "c2c_cli.py",
        "c2c_history.py",
        "c2c_status.py",
        "c2c_smoke_test.py",
        "c2c_sweep_dryrun.py",
        "c2c_mcp.py",
        "c2c_registry.py",
        "claude_send_msg.py",
        "claude_list_sessions.py",
    ]:
        shutil.copy2(source_root / relative_path, target_root / relative_path)

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

    def test_seeded_alias_allocation_starts_from_session_specific_offset(self):
        words = ["aava", "ilma", "kaiku", "sisu"]

        self.assertNotEqual(
            c2c_registry.allocate_unique_alias(words, set(), seed="alpha"),
            c2c_registry.allocate_unique_alias(words, set(), seed="beta"),
        )

    def test_seeded_alias_allocation_wraps_to_available_pair(self):
        words = ["aava", "ilma"]
        first = c2c_registry.allocate_unique_alias(words, set(), seed="session-a")
        existing = {
            first,
            "aava-aava",
            "aava-ilma",
            "ilma-aava",
            "ilma-ilma",
        } - {first}

        self.assertEqual(
            c2c_registry.allocate_unique_alias(words, existing, seed="session-a"),
            first,
        )


class RegistryJsonFallbackTests(unittest.TestCase):
    """Tests for load_registry() falling back to broker JSON registry.

    When registry.yaml doesn't exist (typical in modern setups where the OCaml
    broker uses registry.json), load_registry() should transparently read the
    JSON registry and return data in the same dict format.
    """

    def setUp(self):
        import c2c_registry as _c2c_registry

        self.c2c_registry = _c2c_registry
        self.temp_dir = tempfile.TemporaryDirectory()
        self.td = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_json_registry(self, registrations: list) -> Path:
        json_path = self.td / "registry.json"
        json_path.write_text(json.dumps(registrations), encoding="utf-8")
        return json_path

    def test_fallback_to_json_when_yaml_missing(self):
        """load_registry() returns JSON entries when registry.yaml doesn't exist."""
        regs = [{"session_id": "s-abc", "alias": "test-peer", "pid": 1234}]
        json_path = self._write_json_registry(regs)
        yaml_path = self.td / "registry.yaml"
        # yaml_path intentionally not created

        with mock.patch.object(self.c2c_registry, "default_broker_registry_path", return_value=json_path):
            with mock.patch.object(self.c2c_registry, "registry_path_from_env", return_value=yaml_path):
                result = self.c2c_registry.load_registry()

        self.assertEqual(len(result["registrations"]), 1)
        self.assertEqual(result["registrations"][0]["alias"], "test-peer")

    def test_yaml_takes_precedence_when_both_exist(self):
        """When registry.yaml exists, it is used even if JSON also exists."""
        yaml_path = self.td / "registry.yaml"
        yaml_path.write_text(
            "registrations:\n  - session_id: yaml-sid\n    alias: yaml-peer\n",
            encoding="utf-8",
        )
        json_path = self._write_json_registry([{"session_id": "json-sid", "alias": "json-peer"}])

        with mock.patch.object(self.c2c_registry, "default_broker_registry_path", return_value=json_path):
            result = self.c2c_registry.load_registry(yaml_path)

        # Explicit path → YAML is used
        self.assertEqual(result["registrations"][0]["alias"], "yaml-peer")

    def test_returns_empty_when_neither_exists(self):
        """Returns empty registry when neither YAML nor JSON exists."""
        json_path = self.td / "registry.json"
        yaml_path = self.td / "registry.yaml"
        # Neither file exists — should return empty.
        with mock.patch.object(
            self.c2c_registry, "default_broker_registry_path", return_value=json_path
        ), mock.patch.object(
            self.c2c_registry, "default_registry_path", return_value=yaml_path
        ):
            result = self.c2c_registry.load_registry()

        self.assertEqual(result, {"registrations": []})

    def test_load_broker_json_as_registry_handles_list(self):
        """_load_broker_json_as_registry converts a JSON array to registry format."""
        regs = [{"session_id": "s1", "alias": "a1"}, {"session_id": "s2", "alias": "a2"}]
        json_path = self._write_json_registry(regs)
        result = self.c2c_registry._load_broker_json_as_registry(json_path)
        self.assertEqual(len(result["registrations"]), 2)
        self.assertEqual(result["registrations"][1]["alias"], "a2")

    def test_load_broker_json_as_registry_handles_corrupt_file(self):
        """_load_broker_json_as_registry returns empty on corrupt JSON."""
        bad_path = self.td / "bad.json"
        bad_path.write_text("not json", encoding="utf-8")
        result = self.c2c_registry._load_broker_json_as_registry(bad_path)
        self.assertEqual(result, {"registrations": []})


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
            "If Bash approval allows it, reply with c2c-send <alias> <message...>.\n"
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            event="onboarding",
            sender_name="c2c-register",
            sender_alias="storm-herald",
        )

    def test_register_sends_onboarding_with_onboarding_event_metadata(self):
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
            "If Bash approval allows it, reply with c2c-send <alias> <message...>.\n"
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            event="onboarding",
            sender_name="c2c-register",
            sender_alias="storm-herald",
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
                "c2c",
                "c2c-broker-gc",
                "c2c-claude-wake",
                "c2c-configure-claude-code",
                "c2c-configure-codex",
                "c2c-configure-crush",
                "c2c-configure-kimi",
                "c2c-configure-opencode",
                "c2c-crush-wake",
                "c2c-deliver-inbox",
                "c2c-health",
                "c2c-init",
                "c2c-kimi-wake",
                "c2c-kimi-wire-bridge",
                "c2c-opencode-wake",
                "c2c-prune",
                "c2c-register",
                "c2c-restart-me",
                "c2c-room",
                "c2c-list",
                "c2c-send",
                "c2c-send-all",
                "c2c-setup",
                "c2c-install",
                "c2c-inject",
                "c2c-poker-sweep",
                "c2c-verify",
                "c2c-watch",
                "c2c-whoami",
                "restart-codex-self",
                "restart-crush-self",
                "restart-kimi-self",
                "restart-opencode-self",
                "run-crush-inst",
                "run-crush-inst-outer",
                "run-crush-inst-rearm",
                "run-kimi-inst",
                "run-kimi-inst-outer",
                "run-kimi-inst-rearm",
                "c2c_kimi_prefill.py",
                "c2c_broker_gc.py",
                "c2c_dead_letter.py",
                "c2c_health.py",
                "c2c_register.py",
                "c2c_restart_me.py",
                "c2c_room.py",
                "c2c_configure_claude_code.py",
                "c2c_configure_codex.py",
                "c2c_configure_crush.py",
                "c2c_configure_kimi.py",
                "c2c_configure_opencode.py",
                "c2c_init.py",
                "c2c_list.py",
                "c2c_prune.py",
                "c2c_send.py",
                "c2c_send_all.py",
                "c2c_smoke_test.py",
                "c2c_setup.py",
                "c2c_install.py",
                "c2c_deliver_inbox.py",
                "c2c_inject.py",
                "c2c_poker.py",
                "c2c_poker_sweep.py",
                "c2c_poll_inbox.py",
                "c2c_pts_inject.py",
                "c2c_verify.py",
                "c2c_watch.py",
                "c2c_whoami.py",
                "c2c_claude_wake_daemon.py",
                "c2c_kimi_wake_daemon.py",
                "c2c_kimi_wire_bridge.py",
                "c2c_opencode_wake_daemon.py",
                "c2c_crush_wake_daemon.py",
                "c2c_cli.py",
                "c2c_history.py",
                "c2c_status.py",
                "c2c_smoke_test.py",
                "c2c_sweep_dryrun.py",
                "c2c_mcp.py",
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
    def test_list_registered_sessions_does_not_mutate_registry(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        seeded = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": session["session_id"], "alias": "ember-crown"},
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=[session]),
            ):
                rows = list_registered_sessions()

            reloaded = load_registry(registry_path)

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
        self.assertEqual(reloaded, seeded)

    def test_infer_client_type_from_session_id_and_alias(self):
        from c2c_list import _infer_client_type

        self.assertEqual(
            _infer_client_type("storm-beacon", "d16034fc-5526-414b-a88e-709d1a93e345"),
            "claude-code",
        )
        self.assertEqual(
            _infer_client_type(
                "claude-bob-local", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            ),
            "claude-code",
        )
        self.assertEqual(_infer_client_type("codex", "codex-local"), "codex")
        self.assertEqual(
            _infer_client_type("codex-worker", "codex-worker-session"), "codex"
        )
        self.assertEqual(
            _infer_client_type("opencode-local", "opencode-local"), "opencode"
        )
        self.assertEqual(_infer_client_type("opencode-x", "opencode-x"), "opencode")
        self.assertEqual(
            _infer_client_type("kimi-alice-host", "kimi-alice-host"), "kimi"
        )
        self.assertEqual(
            _infer_client_type("crush-bob-host", "crush-bob-host"), "crush"
        )
        self.assertEqual(_infer_client_type("mystery", "mystery-session"), "?")

    def test_list_broker_flag_reads_broker_registry(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {"session_id": "codex-local", "alias": "codex"},
                        {"session_id": "opencode-local", "alias": "gpt"},
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO / "c2c_list.py"),
                    "--broker",
                    "--json",
                ],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        peers_by_alias = {p["alias"]: p for p in payload["peers"]}
        self.assertIn("codex", peers_by_alias)
        self.assertIn("gpt", peers_by_alias)
        # New fields: alive (None when no pid) and rooms (empty list)
        self.assertIsNone(peers_by_alias["codex"]["alive"])
        self.assertEqual(peers_by_alias["codex"]["rooms"], [])
        self.assertEqual(peers_by_alias["codex"]["session_id"], "codex-local")
        self.assertEqual(peers_by_alias["codex"]["client_type"], "codex")
        self.assertIsNone(peers_by_alias["gpt"]["alive"])
        self.assertEqual(peers_by_alias["gpt"]["session_id"], "opencode-local")
        self.assertEqual(peers_by_alias["gpt"]["client_type"], "opencode")
        # last_seen is None when no inbox file exists
        self.assertIsNone(peers_by_alias["codex"]["last_seen"])
        self.assertIsNone(peers_by_alias["gpt"]["last_seen"])

    def _make_dead_broker(self) -> tempfile.TemporaryDirectory:
        """Helper: broker root with one dead (pid=99999999) peer."""
        tmp = tempfile.TemporaryDirectory()
        (Path(tmp.name) / "registry.json").write_text(
            json.dumps([{"session_id": "s1", "alias": "dead-peer", "pid": 99999999}]),
            encoding="utf-8",
        )
        return tmp

    def _run_list_broker(self, broker_root: str, outer_state: dict) -> str:
        """Call c2c_list.main(["--broker"]) with a mocked outer-loop check and capture stdout."""
        import io
        import c2c_list
        from contextlib import redirect_stdout

        buf = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": broker_root}),
            mock.patch("c2c_health.check_outer_loops", return_value=outer_state),
            redirect_stdout(buf),
        ):
            c2c_list.main(["--broker"])
        return buf.getvalue()

    def test_list_broker_text_suggests_sweep_when_safe(self):
        """Safe-to-sweep: suggest 'c2c sweep'."""
        tmp = self._make_dead_broker()
        try:
            output = self._run_list_broker(
                tmp.name, {"safe_to_sweep": True, "running": []}
            )
        finally:
            tmp.cleanup()
        self.assertIn("c2c sweep", output)
        self.assertNotIn("outer loops running", output)

    def test_list_broker_text_warns_when_outer_loops_present(self):
        """Outer loops running: warn instead of suggesting sweep."""
        tmp = self._make_dead_broker()
        try:
            outer_state = {
                "safe_to_sweep": False,
                "running": [
                    {
                        "client": "codex",
                        "pid": 1234,
                        "instance": "local",
                        "cmdline": "x",
                    }
                ],
            }
            output = self._run_list_broker(tmp.name, outer_state)
        finally:
            tmp.cleanup()
        self.assertIn("outer loops running", output)
        self.assertIn("codex", output)
        self.assertNotIn("run `c2c sweep`", output)

    def test_pid_alive_handles_spaces_in_process_name(self):
        """_pid_alive must parse /proc/pid/stat correctly when comm contains spaces.

        Without the fix, stat.split() misaligns the starttime field for names
        like 'Kimi Code', causing a matching PID to appear dead.

        After last ')': parts[0]=state, parts[1..18]=ppid..itrealvalue, parts[19]=starttime.
        """
        import c2c_list

        fake_pid = os.getpid()
        starttime = 30294636
        # 18 filler fields (1-18) after state so parts[19] == starttime
        fake_stat = (
            f"{fake_pid} (Kimi Code) S 1 2 3 4 5 6 "
            f"7 8 9 10 11 12 13 14 15 16 17 18 {starttime} 21 22\n"
        )
        with (
            mock.patch("pathlib.Path.read_text", return_value=fake_stat),
            mock.patch("pathlib.Path.exists", return_value=True),
        ):
            result = c2c_list._pid_alive(fake_pid, starttime)
        self.assertTrue(result, "should be alive when starttime matches")

    def test_pid_alive_detects_pid_reuse_with_spaces_in_process_name(self):
        """_pid_alive returns False when starttime mismatches (PID reused), even for spaced names."""
        import c2c_list

        fake_pid = os.getpid()
        starttime = 30294636
        fake_stat = (
            f"{fake_pid} (Kimi Code) S 1 2 3 4 5 6 "
            f"7 8 9 10 11 12 13 14 15 16 17 18 {starttime} 21 22\n"
        )
        wrong_starttime = 12345
        with (
            mock.patch("pathlib.Path.read_text", return_value=fake_stat),
            mock.patch("pathlib.Path.exists", return_value=True),
        ):
            result = c2c_list._pid_alive(fake_pid, wrong_starttime)
        self.assertFalse(result, "should be dead when starttime mismatches")

    def test_list_sessions_includes_alias_for_registered_live_sessions(self):
        sessions = [
            {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID},
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]
        seeded = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=sessions),
            ):
                rows = list_sessions(include_all=True)

        self.assertEqual(
            rows,
            [
                {
                    "alias": "storm-herald",
                    "name": "agent-one",
                    "session_id": AGENT_ONE_SESSION_ID,
                },
                {
                    "alias": "",
                    "name": "agent-two",
                    "session_id": AGENT_TWO_SESSION_ID,
                },
            ],
        )


class RegistryReadPathsDoNotMutateTests(unittest.TestCase):
    """Regression for the alias-churn-on-restart bug.

    Read commands (`c2c list`, `c2c send`, `c2c verify`) must not prune the
    YAML registry based on /proc-detected live Claude sessions. Pruning on
    read paths wiped entries for any agent whose process was briefly offline
    (e.g. mid-restart-self), causing it to allocate a fresh alias on
    re-register and silently breaking peer recognition across the swarm. See
    .collab/findings/2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md.
    """

    def _seeded(self) -> dict:
        return {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                {
                    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
                    "alias": "storm-lantern",
                },
            ]
        }

    def test_c2c_list_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        only_one_live = [
            {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=only_one_live),
            ):
                list_registered_sessions()
                list_sessions(include_all=True)

            self.assertEqual(load_registry(registry_path), seeded)

    def test_c2c_send_resolve_alias_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        target_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_send.load_sessions", return_value=[target_session]),
            ):
                session, registration = c2c_send.resolve_alias("ember-crown")

            self.assertEqual(session, target_session)
            self.assertEqual(registration["alias"], "ember-crown")
            self.assertEqual(load_registry(registry_path), seeded)

    def test_c2c_verify_progress_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        only_one_live = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=only_one_live),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    return_value={"sent": 1, "received": 1},
                ),
            ):
                c2c_verify.verify_progress()

            self.assertEqual(load_registry(registry_path), seeded)


if __name__ == "__main__":
    unittest.main()
