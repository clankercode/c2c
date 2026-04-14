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

import c2c_mcp
from c2c_registry import save_registry


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

    def test_list_all_shows_live_sessions_even_when_unregistered(self):
        listed = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            payload["sessions"],
            [
                {
                    "alias": "",
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

    def test_list_all_includes_alias_when_live_session_is_registered(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-one", "--json", env=self.env
        )

        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]

        listed = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            payload["sessions"],
            [
                {
                    "alias": alias,
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

    def test_list_all_human_output_shows_live_sessions(self):
        listed = self.invoke_cli("c2c-list", "--all", env=self.env)

        self.assertEqual(result_code(listed), 0)
        self.assertEqual(
            listed.stdout.splitlines(),
            [
                f"\tagent-one\t{AGENT_ONE_SESSION_ID}",
                f"\tagent-two\t{AGENT_TWO_SESSION_ID}",
            ],
        )

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

        # Use a shared temp registry so both checkouts see the same registrations.
        shared_registry = Path(self.temp_dir.name) / "shared-registry.yaml"
        shared_broker_root = Path(self.temp_dir.name) / "shared-broker"

        env = {
            "C2C_REGISTRY_PATH": str(shared_registry),
            "C2C_MCP_BROKER_ROOT": str(shared_broker_root),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
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

    def test_register_updates_broker_registry_json(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        del env["C2C_REGISTRY_PATH"]

        result = self.invoke_cli("c2c-register", "agent-one", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        broker_data = json.loads(
            (broker_root / "registry.json").read_text(encoding="utf-8")
        )
        self.assertEqual(len(broker_data), 1)
        self.assertEqual(broker_data[0]["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(broker_data[0]["alias"], payload["alias"])
        self.assertIsInstance(broker_data[0].get("pid"), int)
        self.assertIsInstance(broker_data[0].get("pid_start_time"), int)

    def test_sync_broker_registry_writes_json_atomically(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        replaced = []
        original_replace = os.replace

        def tracking_replace(src, dst):
            replaced.append((src, dst))
            return original_replace(src, dst)

        with (
            mock.patch.dict(
                os.environ,
                {"C2C_REGISTRY_PATH": str(self.registry_path)},
                clear=False,
            ),
            mock.patch("c2c_mcp.os.replace", side_effect=tracking_replace),
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(len(replaced), 1)
        _, destination = replaced[0]
        self.assertEqual(Path(destination), broker_root / "registry.json")
        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [{"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}],
        )

    def test_sync_broker_registry_preserves_broker_only_registrations(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": "codex-local", "alias": "codex"},
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "old-alias"},
                ]
            ),
            encoding="utf-8",
        )
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                {"session_id": "codex-local", "alias": "codex"},
            ],
        )

    def test_sync_broker_registry_preserves_liveness_metadata_for_yaml_backed_peer(
        self,
    ):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-ember",
                        "pid": 4242,
                        "pid_start_time": 9999,
                    }
                ]
            ),
            encoding="utf-8",
        )
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {
                    "session_id": AGENT_ONE_SESSION_ID,
                    "alias": "storm-ember",
                    "pid": 4242,
                    "pid_start_time": 9999,
                }
            ],
        )

    def test_sync_broker_registry_preserves_broker_only_liveness_metadata(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": "codex-local",
                        "alias": "codex",
                        "pid": 123,
                        "pid_start_time": 456,
                    }
                ]
            ),
            encoding="utf-8",
        )
        save_registry({"registrations": []}, self.registry_path)

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {
                    "session_id": "codex-local",
                    "alias": "codex",
                    "pid": 123,
                    "pid_start_time": 456,
                }
            ],
        )

def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
