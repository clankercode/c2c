import io
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from threading import BrokenBarrierError
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_register
import c2c_registry
import c2c_deliver_inbox
import c2c_inject
import c2c_mcp
import c2c_poll_inbox
import c2c_poker
import c2c_prune
import c2c_send
import c2c_cli
import c2c_verify
import c2c_whoami
import claude_list_sessions
import claude_send_msg
from c2c_list import list_registered_sessions, list_sessions
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
        "c2c",
        "c2c-broker-gc",
        "c2c-configure-claude-code",
        "c2c-configure-codex",
        "c2c-configure-crush",
        "c2c-configure-kimi",
        "c2c-configure-opencode",
        "c2c-deliver-inbox",
        "c2c-health",
        "c2c-init",
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
        "c2c_broker_gc.py",
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
        "c2c_setup.py",
        "c2c_install.py",
        "c2c_deliver_inbox.py",
        "c2c_inject.py",
        "c2c_poker.py",
        "c2c_poker_sweep.py",
        "c2c_poll_inbox.py",
        "c2c_verify.py",
        "c2c_watch.py",
        "c2c_whoami.py",
        "c2c_health.py",
        "c2c_cli.py",
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
                "c2c",
                "c2c-broker-gc",
                "c2c-configure-claude-code",
                "c2c-configure-codex",
                "c2c-configure-crush",
                "c2c-configure-kimi",
                "c2c-configure-opencode",
                "c2c-deliver-inbox",
                "c2c-health",
                "c2c-init",
                "c2c-inject",
                "c2c-install",
                "c2c-list",
                "c2c-poker-sweep",
                "c2c-poll-inbox",
                "c2c-prune",
                "c2c-register",
                "c2c-restart-me",
                "c2c-room",
                "c2c-send",
                "c2c-send-all",
                "c2c-setup",
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
            ],
        )
        self.assertTrue((install_dir / "c2c").exists())
        self.assertTrue((install_dir / "c2c-configure-claude-code").exists())
        self.assertTrue((install_dir / "c2c-configure-opencode").exists())
        self.assertTrue((install_dir / "c2c-deliver-inbox").exists())
        self.assertTrue((install_dir / "c2c-inject").exists())
        self.assertTrue((install_dir / "c2c-poker-sweep").exists())
        self.assertTrue((install_dir / "c2c-poll-inbox").exists())
        self.assertTrue((install_dir / "c2c-prune").exists())
        self.assertTrue((install_dir / "c2c-register").exists())
        self.assertTrue((install_dir / "c2c-room").exists())
        self.assertTrue((install_dir / "c2c-setup").exists())
        self.assertTrue((install_dir / "restart-opencode-self").exists())
        self.assertTrue((install_dir / "run-kimi-inst").exists())
        self.assertTrue((install_dir / "run-crush-inst").exists())
        self.assertTrue((install_dir / "c2c-watch").exists())
        self.assertTrue((install_dir / "c2c-whoami").exists())

    def test_c2c_list_subcommand_matches_wrapper_json_output(self):
        wrapper = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)
        canonical = self.invoke_cli("c2c", "list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(wrapper), 0)
        self.assertEqual(result_code(canonical), 0)
        self.assertEqual(json.loads(canonical.stdout), json.loads(wrapper.stdout))

    def test_c2c_send_subcommand_matches_wrapper_dry_run_output(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-two", "--json", env=self.env
        )
        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]

        wrapper = self.invoke_cli(
            "c2c-send", alias, "hello", "peer", "--dry-run", "--json", env=self.env
        )
        canonical = self.invoke_cli(
            "c2c", "send", alias, "hello", "peer", "--dry-run", "--json", env=self.env
        )

        self.assertEqual(result_code(wrapper), 0)
        self.assertEqual(result_code(canonical), 0)
        self.assertEqual(json.loads(canonical.stdout), json.loads(wrapper.stdout))

    def test_c2c_mcp_subcommand_dispatches_to_mcp_wrapper(self):
        with mock.patch("c2c_cli.c2c_mcp.main", return_value=0) as mcp_main:
            result = c2c_cli.main(["mcp", "--help"])

        self.assertEqual(result, 0)
        mcp_main.assert_called_once_with(["--help"])

    def test_c2c_inject_subcommand_dispatches_to_cross_client_injector(self):
        with mock.patch("c2c_cli.c2c_inject.main", return_value=0) as inject_main:
            result = c2c_cli.main(["inject", "--pid", "123", "hello"])

        self.assertEqual(result, 0)
        inject_main.assert_called_once_with(["--pid", "123", "hello"])

    def test_c2c_deliver_inbox_subcommand_dispatches_to_delivery_tool(self):
        with mock.patch(
            "c2c_cli.c2c_deliver_inbox.main", return_value=0
        ) as deliver_main:
            result = c2c_cli.main(
                ["deliver-inbox", "--pid", "123", "--session-id", "s"]
            )

        self.assertEqual(result, 0)
        deliver_main.assert_called_once_with(["--pid", "123", "--session-id", "s"])

    def test_c2c_poll_inbox_subcommand_dispatches_to_recovery_poller(self):
        with mock.patch("c2c_cli.c2c_poll_inbox.main", return_value=0) as poll_main:
            result = c2c_cli.main(["poll-inbox", "--json"])

        self.assertEqual(result, 0)
        poll_main.assert_called_once_with(["--json"])

    def test_c2c_send_all_subcommand_dispatches_to_broadcast_client(self):
        with mock.patch("c2c_cli.c2c_send_all.main", return_value=0) as send_all_main:
            result = c2c_cli.main(
                ["send-all", "--from-alias", "me", "hello swarm", "--json"]
            )

        self.assertEqual(result, 0)
        send_all_main.assert_called_once_with(
            ["--from-alias", "me", "hello swarm", "--json"]
        )

    def test_c2c_init_subcommand_dispatches_to_bootstrap(self):
        with mock.patch("c2c_cli.c2c_init.main", return_value=0) as init_main:
            result = c2c_cli.main(["init", "--json"])

        self.assertEqual(result, 0)
        init_main.assert_called_once_with(["--json"])

    def test_c2c_init_creates_broker_root_and_reports_peers(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "fresh-broker"
            self.assertFalse(broker_root.exists())
            env = os.environ.copy()
            env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
            result = subprocess.run(
                [sys.executable, str(REPO / "c2c_init.py"), "--json"],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["broker_root"], str(broker_root))
            self.assertEqual(payload["peer_count"], 0)
            self.assertEqual(payload["aliases"], [])
            self.assertTrue(broker_root.exists())

            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {"session_id": "alice-local", "alias": "alice"},
                        {"session_id": "bob-local", "alias": "bob"},
                    ]
                ),
                encoding="utf-8",
            )
            second = subprocess.run(
                [sys.executable, str(REPO / "c2c_init.py"), "--json"],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
            self.assertEqual(second.returncode, 0, msg=second.stderr)
            second_payload = json.loads(second.stdout)
            self.assertEqual(second_payload["peer_count"], 2)
            self.assertEqual(sorted(second_payload["aliases"]), ["alice", "bob"])

    def test_c2c_mcp_defaults_broker_root_to_shared_git_c2c_dir(self):
        expected = REPO / ".git" / "c2c" / "mcp"
        with mock.patch.dict(os.environ, {}, clear=False):
            self.assertEqual(c2c_mcp.default_broker_root(), expected)

    def test_c2c_mcp_infers_session_id_when_env_not_set(self):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions",
                return_value=[
                    {
                        "name": "agent-one",
                        "pid": 11111,
                        "session_id": AGENT_ONE_SESSION_ID,
                    }
                ],
            ),
            mock.patch(
                "c2c_mcp.find_session",
                return_value={
                    "name": "agent-one",
                    "pid": 11111,
                    "session_id": AGENT_ONE_SESSION_ID,
                },
            ),
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

    def test_c2c_mcp_default_session_id_retries_briefly_for_fresh_session_file(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions", side_effect=[[], [session]]
            ) as load_mock,
            mock.patch("c2c_mcp.find_session", side_effect=[None, session]),
            mock.patch("c2c_mcp.time.monotonic", side_effect=[100.0, 100.01]),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

        self.assertEqual(load_mock.call_count, 2)
        sleep_mock.assert_called_once_with(
            c2c_mcp.SESSION_DISCOVERY_POLL_INTERVAL_SECONDS
        )

    def test_c2c_mcp_default_session_id_waits_long_enough_for_real_startup(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions",
                side_effect=[[], [], [], [], [], [session]],
            ) as load_mock,
            mock.patch(
                "c2c_mcp.find_session",
                side_effect=[None, None, None, None, None, session],
            ),
            mock.patch(
                "c2c_mcp.time.monotonic",
                side_effect=[100.0, 100.05, 100.10, 100.15, 100.20, 100.25],
            ),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

        self.assertEqual(load_mock.call_count, 6)
        self.assertEqual(sleep_mock.call_count, 5)

    def test_c2c_mcp_default_session_id_stops_after_bounded_wait(self):
        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch("c2c_mcp.load_sessions", side_effect=[[], []]) as load_mock,
            mock.patch("c2c_mcp.find_session", side_effect=[None, None]),
            mock.patch("c2c_mcp.time.monotonic", side_effect=[100.0, 100.5, 110.1]),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            with self.assertRaisesRegex(ValueError, "session not found: 11111"):
                c2c_mcp.default_session_id()

        self.assertEqual(load_mock.call_count, 2)
        sleep_mock.assert_called_once_with(
            c2c_mcp.SESSION_DISCOVERY_POLL_INTERVAL_SECONDS
        )

    def test_c2c_mcp_main_warns_and_skips_session_env_when_current_session_unresolvable(
        self,
    ):
        stderr = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"C2C_MCP_SESSION_ID": ""}, clear=False),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch(
                "c2c_mcp.default_session_id",
                side_effect=ValueError(
                    "could not resolve current session uniquely; use a session ID or PID"
                ),
            ),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", stderr),
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], str(REPO / ".git" / "c2c" / "mcp"))
        # The key may be absent OR empty — either means session ID was not resolved.
        self.assertFalse(
            env.get("C2C_MCP_SESSION_ID"),
            "session ID should be unset when discovery fails",
        )
        warning = stderr.getvalue()
        self.assertIn("c2c_mcp: WARNING session discovery failed", warning)
        self.assertIn("tool calls will need an explicit session_id", warning)

    def test_c2c_mcp_main_exports_parent_client_pid_for_server_register(self):
        with (
            mock.patch.dict(os.environ, {"C2C_MCP_SESSION_ID": ""}, clear=False),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.os.getppid", return_value=424242),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_SESSION_ID"], AGENT_ONE_SESSION_ID)
        self.assertEqual(env["C2C_MCP_CLIENT_PID"], "424242")

    def test_c2c_mcp_stdio_initialize_smoke(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_ONE_SESSION_ID
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            }
        )
        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(body + "\n")
            process.stdin.flush()

            payload = process.stdout.readline()
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertIn('"protocolVersion":"2024-11-05"', payload)

    def test_c2c_mcp_main_seeds_broker_registry_and_session_env(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    # Clear any real session ID so default_session_id() is invoked.
                    "C2C_MCP_SESSION_ID": "",
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry") as sync_registry,
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        sync_registry.assert_called_once_with(broker_root)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].kwargs["env"]["C2C_MCP_SESSION_ID"],
            AGENT_ONE_SESSION_ID,
        )
        self.assertEqual(
            run_mock.call_args_list[1].kwargs["env"]["C2C_MCP_BROKER_ROOT"],
            str(broker_root),
        )

    def test_c2c_mcp_main_builds_server_before_launch(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch(
                "c2c_mcp.built_server_path",
                return_value=REPO
                / "_build"
                / "default"
                / "ocaml"
                / "server"
                / "c2c_mcp_server.exe",
            ),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.side_effect = [
                mock.Mock(returncode=0),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[0].args[0],
            [
                "opam",
                "exec",
                "--switch=/home/xertrov/src/call-coding-clis/ocaml",
                "--",
                "dune",
                "build",
                "--root",
                str(REPO),
                "./ocaml/server/c2c_mcp_server.exe",
            ],
        )

    def test_c2c_mcp_main_launches_built_server_directly(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = (
            REPO / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"
        )

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.side_effect = [
                mock.Mock(returncode=0),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        launch_call = run_mock.call_args_list[1]
        self.assertEqual(launch_call.args[0], [str(built_server), "--help"])
        self.assertEqual(launch_call.kwargs["cwd"], REPO)
        self.assertNotIn("bash", launch_call.args[0])

    def test_c2c_mcp_emits_channel_notification_for_session_inbox(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_TWO_SESSION_ID
        env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "1"

        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            ),
            encoding="utf-8",
        )
        (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-ember",
                        "to_alias": "storm-storm",
                        "content": "debate opener",
                    }
                ]
            ),
            encoding="utf-8",
        )

        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"experimental": {"claude/channel": {}}},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            }
        )
        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(body + "\n")
            process.stdin.flush()

            init_payload = process.stdout.readline()
            notif_payload = process.stdout.readline()
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        init_json = json.loads(init_payload)
        notif_json = json.loads(notif_payload)

        self.assertEqual(init_json["result"]["protocolVersion"], "2024-11-05")
        self.assertIn("instructions", init_json["result"])
        self.assertEqual(notif_json["jsonrpc"], "2.0")
        self.assertEqual(notif_json["method"], "notifications/claude/channel")
        self.assertEqual(notif_json["params"]["content"], "debate opener")
        self.assertEqual(notif_json["params"]["meta"]["from_alias"], "storm-ember")
        self.assertEqual(notif_json["params"]["meta"]["to_alias"], "storm-storm")

    def test_c2c_mcp_auto_drain_can_be_disabled_for_polling_clients(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_TWO_SESSION_ID
        env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"

        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            ),
            encoding="utf-8",
        )
        (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-ember",
                        "to_alias": "storm-storm",
                        "content": "poll me",
                    }
                ]
            ),
            encoding="utf-8",
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            init_payload = json.loads(process.stdout.readline())

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "poll_inbox", "arguments": {}},
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            poll_payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(init_payload["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(poll_payload["id"], 2)
        self.assertEqual(poll_payload["result"]["isError"], False)
        messages = json.loads(poll_payload["result"]["content"][0]["text"])
        self.assertEqual(
            messages,
            [
                {
                    "from_alias": "storm-ember",
                    "to_alias": "storm-storm",
                    "content": "poll me",
                }
            ],
        )

    def test_c2c_mcp_whoami_uses_current_session_registration(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_SESSION_ID"] = AGENT_ONE_SESSION_ID
        env["C2C_MCP_SESSION_ID"] = AGENT_ONE_SESSION_ID
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            process.stdout.readline()

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "whoami", "arguments": {}},
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(payload["result"]["isError"], False)
        self.assertEqual(payload["result"]["content"][0]["text"], "storm-ember")

    def test_c2c_mcp_send_resolves_aliases_from_cli_registry(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_SESSION_ID"] = AGENT_ONE_SESSION_ID
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            },
            self.registry_path,
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            process.stdout.readline()

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {
                            "name": "send",
                            "arguments": {
                                "from_alias": "storm-ember",
                                "to_alias": "storm-storm",
                                "content": "hello from mcp",
                            },
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(payload["result"]["isError"], False)
        receipt = json.loads(payload["result"]["content"][0]["text"])
        self.assertTrue(receipt["queued"])
        self.assertIn("ts", receipt)
        self.assertEqual(
            json.loads(
                (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").read_text(
                    encoding="utf-8"
                )
            ),
            [
                {
                    "from_alias": "storm-ember",
                    "to_alias": "storm-storm",
                    "content": "hello from mcp",
                }
            ],
        )

    def test_register_updates_broker_registry_json_alongside_yaml(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)

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

    def test_install_reports_path_guidance_when_bin_not_on_path(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)
        env["PATH"] = "/usr/bin"

        result = self.invoke_cli("c2c-install", env=env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("not currently on PATH", result.stdout)

    def test_run_codex_inst_dry_run_builds_resume_command_with_unique_c2c_id(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-a.json").write_text(
            json.dumps(
                {
                    "command": "codex",
                    "mode": "resume",
                    "resume": "019d8483-ad93-72f1-85ba-e14f0f7e743d",
                    "flags": [
                        "--ask-for-approval",
                        "never",
                        "--sandbox",
                        "danger-full-access",
                    ],
                    "cwd": str(REPO),
                    "prompt": "Poll c2c and continue.",
                    "title": "codex-a",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "codex-a", "--search", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["cwd"], str(REPO))
        self.assertEqual(payload["pid_file"], str(config_dir / "codex-a.pid"))
        self.assertEqual(payload["env"]["RUN_CODEX_INST_NAME"], "codex-a")
        self.assertEqual(
            payload["env"]["RUN_CODEX_INST_C2C_SESSION_ID"], "codex-codex-a"
        )
        self.assertEqual(
            payload["launch"],
            [
                "codex",
                "--ask-for-approval",
                "never",
                "--sandbox",
                "danger-full-access",
                "--search",
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_SESSION_ID="codex-codex-a"',
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_AUTO_DRAIN_CHANNEL="0"',
                "resume",
                "019d8483-ad93-72f1-85ba-e14f0f7e743d",
                "Poll c2c and continue.",
            ],
        )

    def test_c2c_poker_default_message_orients_idle_agent_to_continue(self):
        message = c2c_poker.DEFAULT_MESSAGE

        self.assertIn("Poll your C2C inbox", message)
        self.assertIn("tmp_status.txt", message)
        self.assertIn("tmp_collab_lock.md", message)
        self.assertIn("Empty inbox is not a stop signal", message)
        self.assertIn("highest-leverage unblocked", message)
        self.assertNotIn("ignore", message.lower())

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

    def test_run_codex_inst_allows_explicit_c2c_id_for_multiple_codex_sessions(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "reviewer.json").write_text(
            json.dumps(
                {
                    "mode": "exec-resume",
                    "resume": "test-codex-for-injection",
                    "c2c_session_id": "codex-reviewer-1",
                    "cwd": str(REPO),
                    "prompt": "Poll c2c once.",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "reviewer", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["env"]["RUN_CODEX_INST_C2C_SESSION_ID"], "codex-reviewer-1"
        )
        self.assertEqual(
            payload["launch"],
            [
                "codex",
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_SESSION_ID="codex-reviewer-1"',
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_AUTO_DRAIN_CHANNEL="0"',
                "exec",
                "resume",
                "test-codex-for-injection",
                "Poll c2c once.",
            ],
        )

    def test_run_codex_inst_passes_alias_hint_to_mcp_auto_register(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-main.json").write_text(
            json.dumps(
                {
                    "mode": "resume",
                    "resume": "test-codex-for-restart",
                    "c2c_session_id": "codex-local",
                    "c2c_alias": "codex",
                    "cwd": str(REPO),
                    "prompt": "Poll c2c once.",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "codex-main", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn(
            'mcp_servers.c2c.env.C2C_MCP_AUTO_REGISTER_ALIAS="codex"',
            payload["launch"],
        )
        self.assertEqual(payload["env"]["RUN_CODEX_INST_ALIAS_HINT"], "codex")

    def test_run_codex_inst_outer_dry_run_reports_inner_launch_command(self):
        env = dict(self.env)
        env["RUN_CODEX_INST_OUTER_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst-outer", "codex-a", "--search", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:], [str(REPO / "run-codex-inst"), "codex-a", "--search"]
        )

    def test_run_codex_inst_rearm_dry_run_reports_bg_loop_commands(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-a.pid").write_text("12345\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-codex-inst-rearm",
            "codex-a",
            "--session-id",
            "codex-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "codex-a")
        self.assertEqual(payload["target_pid"], 12345)
        self.assertEqual(payload["session_id"], "codex-a-local")
        self.assertTrue(payload["dry_run"])
        self.assertEqual(
            payload["pidfiles"],
            {
                "poker": str(config_dir / "codex-a.poker.pid"),
                "deliver": str(config_dir / "codex-a.deliver.pid"),
            },
        )
        joined_commands = "\n".join(
            " ".join(command) for command in payload["commands"]
        )
        self.assertIn("c2c_poker.py", joined_commands)
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id codex-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)
        self.assertIn("--daemon-timeout 30", joined_commands)

    def test_codex_b4_config_rearms_bg_loops_before_resume(self):
        config = json.loads(
            (REPO / "run-codex-inst.d" / "c2c-codex-b4.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertEqual(
            config["pre_exec"],
            [str(REPO / "run-codex-inst-rearm"), "c2c-codex-b4"],
        )

    def test_restart_codex_self_dry_run_reads_pid_file_without_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            (config_dir / "codex-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_CODEX_INST_NAME"] = "codex-a"
            env["RUN_CODEX_RESTART_SELF_DRY_RUN"] = "1"

            result = run_cli("restart-codex-self", "--expect-comm", "sleep", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["name"], "codex-a")
            self.assertEqual(payload["pid"], sleeper.pid)
            self.assertEqual(payload["pid_file"], str(config_dir / "codex-a.pid"))
            self.assertEqual(payload["signal"], "SIGTERM")
            self.assertEqual(payload["comm"], "sleep")
            self.assertEqual(payload["dry_run"], True)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_codex_self_writes_reason_marker_before_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            (config_dir / "codex-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_CODEX_INST_NAME"] = "codex-a"
            env["RUN_CODEX_RESTART_SELF_DRY_RUN"] = "0"

            result = run_cli(
                "restart-codex-self",
                "--expect-comm",
                "sleep",
                "--reason",
                "rebuilt c2c mcp after startup failure",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            marker_path = config_dir / "codex-a.restart.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            self.assertEqual(marker["name"], "codex-a")
            self.assertEqual(marker["pid"], sleeper.pid)
            self.assertEqual(marker["signal"], "SIGTERM")
            self.assertEqual(marker["reason"], "rebuilt c2c mcp after startup failure")
            self.assertFalse(marker["dry_run"])
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
                try:
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    sleeper.kill()
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_codex_self_requires_instance_name(self):
        env = dict(self.env)
        env["RUN_CODEX_INST_NAME"] = ""

        result = run_cli("restart-codex-self", env=env)

        self.assertEqual(result_code(result), 2)
        self.assertIn("no instance name", result.stderr)

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
                "c2c-configure-claude-code",
                "c2c-configure-codex",
                "c2c-configure-crush",
                "c2c-configure-kimi",
                "c2c-configure-opencode",
                "c2c-deliver-inbox",
                "c2c-health",
                "c2c-init",
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
                "c2c_broker_gc.py",
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
                "c2c_setup.py",
                "c2c_install.py",
                "c2c_deliver_inbox.py",
                "c2c_inject.py",
                "c2c_poker.py",
                "c2c_poker_sweep.py",
                "c2c_poll_inbox.py",
                "c2c_verify.py",
                "c2c_watch.py",
                "c2c_whoami.py",
                "c2c_cli.py",
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
        self.assertIsNone(peers_by_alias["gpt"]["alive"])
        self.assertEqual(peers_by_alias["gpt"]["session_id"], "opencode-local")

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
            mock.patch.dict(
                os.environ,
                {"C2C_SESSION_ID": "", "C2C_SESSION_PID": "", "C2C_MCP_SESSION_ID": ""},
                clear=False,
            ),
        ):
            result = c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        self.assertEqual(result, delegated_result)
        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="c2c-send",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_passes_sender_metadata_when_current_session_registered(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.resolve_sender_metadata",
                return_value={"name": "agent-one", "alias": "storm-herald"},
            ),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="agent-one",
            sender_alias="storm-herald",
            sessions=mock.ANY,
        )

    def test_send_to_alias_passes_mcp_env_sender_metadata_to_pty_delegate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "opencode-local",
                            "alias": "opencode-local",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            session = {
                "name": "agent-two",
                "pid": 11112,
                "session_id": AGENT_TWO_SESSION_ID,
            }
            registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch(
                    "c2c_send.resolve_alias", return_value=(session, registration)
                ),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": "",
                        "C2C_SESSION_PID": "",
                        "C2C_MCP_SESSION_ID": "opencode-local",
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch(
                    "c2c_send.claude_send_msg.send_message_to_session",
                    return_value={"ok": True},
                ) as delegate,
            ):
                c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="opencode-local",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_uses_minimal_sender_fallback_when_current_session_unknown(
        self,
    ):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.resolve_sender_metadata",
                return_value={"name": "c2c-send", "alias": ""},
            ),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="c2c-send",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_reuses_loaded_sessions_for_sender_metadata_and_sendability(
        self,
    ):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}
        sessions = [
            {
                "name": "agent-one",
                "pid": 11111,
                "session_id": AGENT_ONE_SESSION_ID,
                "tty": "/dev/pts/8",
                "terminal_pid": 22222,
                "terminal_master_fd": 7,
            },
            {
                **session,
                "terminal_pid": 33333,
                "terminal_master_fd": 8,
            },
        ]

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch.dict(
                os.environ,
                {"C2C_SESSION_ID": AGENT_ONE_SESSION_ID, "C2C_MCP_SESSION_ID": ""},
                clear=False,
            ),
            mock.patch(
                "c2c_send.load_registration_for_session_id",
                return_value={
                    "session_id": AGENT_ONE_SESSION_ID,
                    "alias": "storm-herald",
                },
            ),
            mock.patch(
                "c2c_send.load_sessions", return_value=sessions
            ) as load_sessions,
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        load_sessions.assert_called_once_with()
        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="agent-one",
            sender_alias="",
            sessions=sessions,
        )

    def test_send_to_alias_broker_only_peer_appends_to_broker_inbox(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                result = c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertTrue(result["ok"])
            self.assertEqual(result["to"], "broker:codex-local")
            self.assertEqual(result["session_id"], "codex-local")
            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "c2c-send",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_broker_only_peer_uses_registered_sender_alias(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )

            with (
                mock.patch(
                    "c2c_send.load_sessions",
                    return_value=[
                        {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID}
                    ],
                ),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": AGENT_ONE_SESSION_ID,
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch(
                    "c2c_send.load_registration_for_session_id",
                    return_value={
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-herald",
                    },
                ),
                mock.patch(
                    "c2c_send.find_session",
                    return_value={
                        "name": "agent-one",
                        "session_id": AGENT_ONE_SESSION_ID,
                    },
                ),
            ):
                c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "storm-herald",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_broker_only_peer_uses_mcp_env_sender_alias(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "opencode-local",
                            "alias": "opencode-local",
                        },
                        {"session_id": "codex-local", "alias": "codex"},
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": "",
                        "C2C_SESSION_PID": "",
                        "C2C_MCP_SESSION_ID": "opencode-local",
                        "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "opencode-local",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_rejects_dead_broker_only_peer(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "codex-local",
                            "alias": "codex",
                            "pid": 4242,
                            "pid_start_time": 9999,
                        }
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch("c2c_send.os.path.exists", return_value=False),
            ):
                with self.assertRaisesRegex(
                    ValueError, "recipient is not alive: codex"
                ):
                    c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertFalse((broker_root / "codex-local.inbox.json").exists())

    def test_send_to_alias_broker_only_peer_concurrent_appends_preserve_all_messages(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )
            inbox_path = broker_root / "codex-local.inbox.json"
            inbox_path.write_text("[]", encoding="utf-8")
            original_read_text = Path.read_text
            worker_count = 8
            start_barrier = threading.Barrier(worker_count)
            read_barrier = threading.Barrier(worker_count)
            errors = []

            def delayed_read_text(path_self, *args, **kwargs):
                if path_self == inbox_path:
                    contents = original_read_text(path_self, *args, **kwargs)
                    try:
                        read_barrier.wait(timeout=0.5)
                    except BrokenBarrierError:
                        pass
                    return contents
                return original_read_text(path_self, *args, **kwargs)

            def worker(index: int) -> None:
                try:
                    start_barrier.wait(timeout=2)
                    c2c_send.send_to_alias(
                        "codex", f"hello peer {index}", dry_run=False
                    )
                except Exception as error:  # pragma: no cover - failure surfaced below
                    errors.append(error)

            with (
                mock.patch("pathlib.Path.read_text", delayed_read_text),
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                threads = [
                    threading.Thread(target=worker, args=(index,))
                    for index in range(worker_count)
                ]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=5)

            self.assertEqual(errors, [])
            items = json.loads(inbox_path.read_text(encoding="utf-8"))
            self.assertEqual(len(items), worker_count)
            self.assertEqual(
                {item["content"] for item in items},
                {f"hello peer {index}" for index in range(worker_count)},
            )

    def test_broker_inbox_write_lock_uses_posix_lockf_for_ocaml_compatibility(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            inbox_path = Path(temp_dir) / "codex-local.inbox.json"

            with mock.patch("c2c_send.fcntl.lockf") as lockf:
                with c2c_send.broker_inbox_write_lock(inbox_path):
                    pass

            self.assertEqual(lockf.call_args_list[0].args[1], c2c_send.fcntl.LOCK_EX)
            self.assertEqual(lockf.call_args_list[1].args[1], c2c_send.fcntl.LOCK_UN)

    def test_broker_inbox_write_lock_uses_ocaml_sidecar_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            inbox_path = Path(temp_dir) / "codex-local.inbox.json"

            with c2c_send.broker_inbox_write_lock(inbox_path):
                self.assertTrue((Path(temp_dir) / "codex-local.inbox.lock").exists())
                self.assertFalse(
                    (Path(temp_dir) / "codex-local.inbox.json.lock").exists()
                )

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


class C2CInjectUnitTests(unittest.TestCase):
    def test_inject_pid_dry_run_resolves_generic_client_without_writing_pty(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_inject.c2c_poker.resolve_pid", return_value=(33333, "9", None)
            ) as resolve_pid,
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "codex",
                    "--pid",
                    "12345",
                    "--dry-run",
                    "--json",
                    "hello",
                    "codex",
                ]
            )

        self.assertEqual(result, 0)
        resolve_pid.assert_called_once_with(12345)
        inject.assert_not_called()
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "codex")
        self.assertEqual(payload["terminal_pid"], 33333)
        self.assertEqual(payload["pts"], "9")
        self.assertTrue(payload["dry_run"])
        self.assertIn('<c2c event="message" from="c2c-inject"', payload["payload"])
        self.assertIn('source="pty"', payload["payload"])
        self.assertIn('source_tool="c2c_inject"', payload["payload"])
        self.assertIn("hello codex", payload["payload"])

    def test_inject_terminal_target_writes_raw_message_for_opencode(self):
        stdout = io.StringIO()

        with (
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--raw",
                    "--json",
                    "raw prompt",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once_with(44444, "12", "raw prompt")
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "opencode")
        self.assertEqual(payload["payload"], "raw prompt")
        self.assertFalse(payload["dry_run"])

    def test_inject_submit_delay_is_forwarded_to_pty_backend(self):
        stdout = io.StringIO()

        with (
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--submit-delay",
                    "1.25",
                    "--raw",
                    "--json",
                    "slow prompt",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once_with(
            44444,
            "12",
            "slow prompt",
            submit_delay=1.25,
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["submit_delay"], 1.25)

    def test_inject_claude_session_uses_claude_resolver(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_inject.c2c_poker.resolve_claude_session",
                return_value=(22222, "11", "/tmp/transcript.jsonl"),
            ) as resolve_claude_session,
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "claude",
                    "--claude-session",
                    "agent-one",
                    "--json",
                    "hello",
                    "claude",
                ]
            )

        self.assertEqual(result, 0)
        resolve_claude_session.assert_called_once_with("agent-one")
        inject.assert_called_once()
        self.assertEqual(inject.call_args.args[0:2], (22222, "11"))
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "claude")
        self.assertIn('source="pty"', payload["payload"])
        self.assertIn('source_tool="c2c_inject"', payload["payload"])
        self.assertIn("hello claude", payload["payload"])


class C2CDeliverInboxUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_deliver_inbox_dry_run_peeks_without_injecting(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "codex",
                        "content": "queued hello",
                    }
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_deliver_inbox.c2c_inject.resolve_target",
                return_value=(33333, "9", None),
            ),
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "codex",
                    "--pid",
                    "12345",
                    "--session-id",
                    "codex-local",
                    "--broker-root",
                    str(broker_root),
                    "--dry-run",
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_not_called()
        self.assertEqual(
            json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
            "queued hello",
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 0)
        self.assertEqual(payload["messages"][0]["content"], "queued hello")

    def test_deliver_inbox_drains_and_injects_each_message(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "opencode",
                        "content": "first",
                    },
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "opencode",
                        "content": "second",
                    },
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_deliver_inbox.c2c_poll_inbox.call_mcp_tool",
                side_effect=RuntimeError("mcp unavailable"),
            ),
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--session-id",
                    "opencode-local",
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual(inject.call_count, 2)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])
        self.assertIn("first", inject.call_args_list[0].args[2])
        self.assertIn("second", inject.call_args_list[1].args[2])
        self.assertIn('source="broker"', inject.call_args_list[0].args[2])
        self.assertIn(
            'source_tool="c2c_deliver_inbox"', inject.call_args_list[0].args[2]
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 2)
        self.assertEqual(payload["target"]["terminal_pid"], 44444)

    def test_deliver_inbox_notify_only_injects_nudge_without_draining_content(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "codex",
                        "to_alias": "opencode-local",
                        "content": "secret content must stay broker-native",
                    }
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--session-id",
                    "opencode-local",
                    "--broker-root",
                    str(broker_root),
                    "--notify-only",
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once()
        payload_text = inject.call_args.args[2]
        self.assertIn("mcp__c2c__poll_inbox", payload_text)
        self.assertIn('source="broker-notify"', payload_text)
        self.assertIn('source_tool="c2c_deliver_inbox"', payload_text)
        self.assertNotIn("secret content", payload_text)
        self.assertEqual(
            json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
            "secret content must stay broker-native",
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 0)
        self.assertTrue(payload["notified"])


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
                "claude_list_sessions.iter_live_claude_processes",
                return_value=iter([]),
            ),
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
                "claude_list_sessions.iter_live_claude_processes",
                return_value=iter([]),
            ),
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
    def test_render_payload_wraps_plain_message_in_single_c2c_root_with_metadata(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="agent-one",
                sender_alias="storm-herald",
            ),
            '<c2c event="message" from="agent-one" alias="storm-herald" source="pty" source_tool="claude_send_msg">\nhello peer\n</c2c>',
        )

    def test_render_payload_omits_alias_when_sender_alias_missing(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="c2c-send",
                sender_alias="",
            ),
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg">\nhello peer\n</c2c>',
        )

    def test_inject_delegates_to_external_pty_helper_with_terminal_metadata(self):
        session = {
            "tty": "/dev/pts/9",
            "terminal_pid": 33333,
        }

        with mock.patch("claude_send_msg.subprocess.run") as run:
            claude_send_msg.inject(session, "hello peer")

        run.assert_called_once_with(
            [str(claude_send_msg.PTY_INJECT), "33333", "9", "hello peer"],
            check=True,
            capture_output=True,
            text=True,
        )

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
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg">\nhello peer\n</c2c>',
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

    def test_send_message_to_session_skips_session_reload_when_sessions_already_provided(
        self,
    ):
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
                "claude_send_msg.load_sessions",
                side_effect=AssertionError("load_sessions should not be called"),
            ),
            mock.patch("claude_send_msg.inject") as inject,
            mock.patch("claude_send_msg.time.time", return_value=123.0),
        ):
            result = claude_send_msg.send_message_to_session(
                partial_session,
                "hello peer",
                sessions=[full_session],
            )

        inject.assert_called_once_with(
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg">\nhello peer\n</c2c>',
        )
        self.assertEqual(result["session_id"], AGENT_TWO_SESSION_ID)

    def test_send_message_to_session_reloads_when_provided_sessions_lack_terminal_owner(
        self,
    ):
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
                partial_session,
                "hello peer",
                sessions=[partial_session],
            )

        load_sessions.assert_called_once_with()
        inject.assert_called_once_with(
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg">\nhello peer\n</c2c>',
        )
        self.assertEqual(result["session_id"], AGENT_TWO_SESSION_ID)


class C2CCLIUnitTests(unittest.TestCase):
    def test_is_safe_auto_approve_command_accepts_allowlisted_c2c_subcommands(self):
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c send storm-ember hi"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c list --all --json"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c whoami --json"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c verify --json"))

    def test_is_safe_auto_approve_command_rejects_non_allowlisted_or_fake_prefixes(
        self,
    ):
        self.assertFalse(c2c_cli.is_safe_auto_approve_command("c2c register agent-one"))
        self.assertFalse(
            c2c_cli.is_safe_auto_approve_command(
                "c2c-but-i-just-named-it-that send storm-ember hi"
            )
        )
        self.assertFalse(
            c2c_cli.is_safe_auto_approve_command("python c2c send storm-ember hi")
        )

    def test_auto_approve_is_disabled_by_default(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            self.assertFalse(c2c_cli.auto_approve_enabled())


class OpenCodeLocalConfigTests(unittest.TestCase):
    def test_opencode_local_config_exposes_c2c_mcp(self):
        config = json.loads(
            (REPO / ".opencode" / "opencode.json").read_text(encoding="utf-8")
        )
        c2c = config["mcp"]["c2c"]
        self.assertEqual(c2c["type"], "local")
        self.assertEqual(c2c["command"][:2], ["python3", str(REPO / "c2c_mcp.py")])
        self.assertEqual(c2c["environment"]["C2C_MCP_SESSION_ID"], "opencode-c2c-msg")
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", c2c["environment"])
        self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertTrue(c2c.get("enabled", True))

    def test_run_opencode_inst_dry_run_reports_local_config_and_session(self):
        env = {"RUN_OPENCODE_INST_DRY_RUN": "1"}
        result = run_cli("run-opencode-inst", "c2c-opencode-local", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_C2C_SESSION_ID"], "opencode-local"
        )
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_CONFIG_PATH"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        # OPENCODE_CONFIG: path opencode reads to find its config
        self.assertEqual(
            payload["env"]["OPENCODE_CONFIG"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        # OPENCODE_CONFIG_CONTENT: content of that file for debugging / dry-run inspection
        env_config = json.loads(payload["env"]["OPENCODE_CONFIG_CONTENT"])
        self.assertEqual(
            env_config["mcp"]["c2c"]["environment"]["C2C_MCP_SESSION_ID"],
            "opencode-local",
        )
        self.assertEqual(payload["cwd"], str(REPO))
        self.assertIn("opencode", payload["launch"][0])
        self.assertIn("run", payload["launch"])
        self.assertEqual(payload["env"]["C2C_MCP_SESSION_ID"], "opencode-local")
        self.assertEqual(
            payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-local"
        )
        self.assertEqual(
            payload["env"]["C2C_MCP_BROKER_ROOT"],
            str(REPO / ".git" / "c2c" / "mcp"),
        )
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_RESTART_MARKER"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.restart.json"),
        )

    def test_run_opencode_inst_rearm_dry_run_reports_bg_loop_commands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            config_dir.mkdir()
            (config_dir / "opencode-a.pid").write_text("12345\n", encoding="utf-8")
            (config_dir / "opencode-a.json").write_text(
                json.dumps(
                    {
                        "c2c_session_id": "opencode-a-local",
                        "c2c_alias": "opencode-a",
                    }
                ),
                encoding="utf-8",
            )
            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                "RUN_OPENCODE_INST_REARM_DRY_RUN": "1",
            }

            result = run_cli("run-opencode-inst-rearm", "opencode-a", "--json", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "opencode-a")
        self.assertEqual(payload["target_pid"], 12345)
        self.assertEqual(payload["session_id"], "opencode-a-local")
        self.assertEqual(payload["alias"], "opencode-a")
        joined_commands = "\n".join(
            " ".join(command) for command in payload["commands"]
        )
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--client opencode", joined_commands)
        self.assertIn("--session-id opencode-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)
        self.assertIn("c2c_poker.py", joined_commands)

    def test_run_opencode_inst_rearm_skips_live_process_without_tty(self):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                config_dir = Path(temp_dir) / "run-opencode-inst.d"
                config_dir.mkdir()
                (config_dir / "opencode-a.json").write_text(
                    json.dumps(
                        {
                            "c2c_session_id": "opencode-a-local",
                            "c2c_alias": "opencode-a",
                        }
                    ),
                    encoding="utf-8",
                )
                env = {"RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)}

                result = run_cli(
                    "run-opencode-inst-rearm",
                    "opencode-a",
                    "--pid",
                    str(sleeper.pid),
                    "--start-timeout",
                    "0.1",
                    "--json",
                    env=env,
                )
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=1)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=1)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["skipped"])
        self.assertEqual(payload["reason"], "target_has_no_tty")
        self.assertIn("no /dev/pts", payload["error"])

    def test_opencode_local_config_sets_stable_c2c_alias(self):
        config = json.loads(
            (REPO / "run-opencode-inst.d" / "c2c-opencode-local.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertEqual(config["c2c_alias"], "opencode-local")
        self.assertEqual(
            config["config_path"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        self.assertNotIn("pre_exec", config)

    def test_run_opencode_inst_uses_c2c_alias_not_session_id_for_auto_register(self):
        """When c2c_alias differs from c2c_session_id, AUTO_REGISTER_ALIAS must
        use the alias so peers can address the managed instance by its stable name."""
        with tempfile.TemporaryDirectory() as temp_dir:
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            config_dir.mkdir()
            managed_config = {
                "command": "opencode",
                "cwd": str(REPO),
                "c2c_session_id": "ses-internal-abc123",
                "c2c_alias": "opencode-special",
                "prompt": "test prompt",
            }
            (config_dir / "special.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            (config_dir / "special.opencode.json").write_text(
                json.dumps({"mcp": {}}), encoding="utf-8"
            )
            # Point at our temp config dir so we don't need a real opencode binary
            managed_config["config_path"] = str(config_dir / "special.opencode.json")
            (config_dir / "special.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_DRY_RUN": "1",
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "special", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        # SESSION_ID stays as the internal session identifier
        self.assertEqual(payload["env"]["C2C_MCP_SESSION_ID"], "ses-internal-abc123")
        # AUTO_REGISTER_ALIAS must be the c2c_alias, not the session_id
        self.assertEqual(
            payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-special"
        )

    def test_run_opencode_inst_outer_dry_run_reports_inner_launch_command(self):
        env = {"RUN_OPENCODE_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-opencode-inst-outer", "c2c-opencode-local", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:],
            [str(REPO / "run-opencode-inst"), "c2c-opencode-local"],
        )
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:],
            [str(REPO / "run-opencode-inst-rearm"), "c2c-opencode-local"],
        )

    def test_run_opencode_inst_outer_forwards_first_sigint_to_child_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            outer_path = root / "run-opencode-inst-outer"
            inner_path = root / "run-opencode-inst"
            signal_path = root / "signal.txt"
            child_pid_path = root / "child.pid"
            launch_log_path = root / "launches.txt"
            shutil.copy2(REPO / "run-opencode-inst-outer", outer_path)
            inner_path.write_text(
                "import os, pathlib, signal, sys, time\n"
                f"signal_path = pathlib.Path({str(signal_path)!r})\n"
                f"child_pid_path = pathlib.Path({str(child_pid_path)!r})\n"
                f"launch_log_path = pathlib.Path({str(launch_log_path)!r})\n"
                "with launch_log_path.open('a', encoding='utf-8') as handle:\n"
                "    handle.write(f'{os.getpid()}\\n')\n"
                "child_pid_path.write_text(f'{os.getpid()}\\n', encoding='utf-8')\n"
                "def handle(signum, _frame):\n"
                "    time.sleep(1.0)\n"
                "    signal_path.write_text(signal.Signals(signum).name + '\\n', encoding='utf-8')\n"
                "    raise SystemExit(0)\n"
                "signal.signal(signal.SIGINT, handle)\n"
                "signal.signal(signal.SIGTERM, handle)\n"
                "while True:\n"
                "    time.sleep(0.1)\n",
                encoding="utf-8",
            )

            process = subprocess.Popen(
                [sys.executable, str(outer_path), "opencode-a"],
                cwd=root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    if child_pid_path.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(child_pid_path.exists(), "child process did not start")

                process.send_signal(signal.SIGINT)

                deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    if signal_path.exists():
                        break
                    time.sleep(0.05)

                launches = launch_log_path.read_text(encoding="utf-8").splitlines()
                self.assertEqual(
                    launches, [child_pid_path.read_text(encoding="utf-8").strip()]
                )

                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=CLI_TIMEOUT_SECONDS)

                self.assertEqual(process.returncode, 130, stderr)
                self.assertTrue(signal_path.exists(), stdout + stderr)
                self.assertEqual(
                    signal_path.read_text(encoding="utf-8").strip(), "SIGINT"
                )
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=CLI_TIMEOUT_SECONDS)

    @unittest.skipUnless(shutil.which("opencode"), "opencode not installed")
    def test_opencode_repo_local_config_lists_c2c_server(self):
        result = subprocess.run(
            ["opencode", "mcp", "list"],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("c2c", result.stdout)
        self.assertIn("c2c_mcp.py", result.stdout)


class C2CConfigureOpencodeTests(unittest.TestCase):
    def test_writes_opencode_config_pointing_at_c2c_mcp_in_target_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            config_path = Path(payload["config_path"])
            self.assertEqual(config_path, target / ".opencode" / "opencode.json")
            self.assertTrue(config_path.exists())
            config = json.loads(config_path.read_text(encoding="utf-8"))
            c2c = config["mcp"]["c2c"]
            self.assertEqual(c2c["type"], "local")
            self.assertEqual(c2c["command"], ["python3", str(REPO / "c2c_mcp.py")])
            self.assertEqual(
                c2c["environment"]["C2C_MCP_BROKER_ROOT"],
                str(REPO / ".git" / "c2c" / "mcp"),
            )
            self.assertEqual(
                c2c["environment"]["C2C_MCP_SESSION_ID"],
                f"opencode-{target.name}",
            )
            self.assertEqual(
                c2c["environment"]["C2C_MCP_AUTO_REGISTER_ALIAS"],
                f"opencode-{target.name}",
            )
            self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
            self.assertTrue(c2c["enabled"])
            self.assertEqual(payload["session_id"], f"opencode-{target.name}")
            self.assertEqual(payload["alias"], f"opencode-{target.name}")

    def test_writes_opencode_config_with_custom_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--alias",
                    "opencode-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            # session_id derived from dir name, alias is the custom value
            self.assertEqual(payload["session_id"], f"opencode-{target.name}")
            self.assertEqual(payload["alias"], "opencode-primary")
            config = json.loads(
                Path(payload["config_path"]).read_text(encoding="utf-8")
            )
            env = config["mcp"]["c2c"]["environment"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], f"opencode-{target.name}")
            self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-primary")

    def test_refuses_to_overwrite_existing_config_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / ".opencode").mkdir()
            existing = target / ".opencode" / "opencode.json"
            existing.write_text('{"keep": "me"}', encoding="utf-8")
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exists", result.stderr.lower())
            self.assertEqual(
                json.loads(existing.read_text(encoding="utf-8")), {"keep": "me"}
            )

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / ".opencode").mkdir()
            existing = target / ".opencode" / "opencode.json"
            existing.write_text('{"keep": "me"}', encoding="utf-8")
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(existing.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcp"])


class RestartOpenCodeSelfTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        # Skip the 1.5s grace-period sleep so tests stay inside CLI_TIMEOUT_SECONDS.
        self.env = {"RUN_OPENCODE_RESTART_SURVIVOR_KILL_DELAY": "0"}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_restart_opencode_self_dry_run_reads_pid_file_without_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        sleeper_pgid = os.getpgid(sleeper.pid)
        try:
            (config_dir / "opencode-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"
            env["RUN_OPENCODE_RESTART_SELF_DRY_RUN"] = "1"

            result = run_cli("restart-opencode-self", "--expect-comm", "sleep", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["name"], "opencode-a")
            self.assertEqual(payload["pid"], sleeper.pid)
            self.assertEqual(payload["pid_file"], str(config_dir / "opencode-a.pid"))
            self.assertEqual(payload["signal"], "SIGTERM")
            self.assertEqual(payload["comm"], "sleep")
            self.assertEqual(payload["process_group"], os.getpgid(sleeper.pid))
            self.assertEqual(payload["dry_run"], True)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_opencode_self_writes_reason_marker_before_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        sleeper_pgid = os.getpgid(sleeper.pid)
        try:
            (config_dir / "opencode-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"
            env["RUN_OPENCODE_RESTART_SELF_DRY_RUN"] = "0"

            result = run_cli(
                "restart-opencode-self",
                "--expect-comm",
                "sleep",
                "--reason",
                "disabled snip plugin; restart managed opencode",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            marker_path = config_dir / "opencode-a.restart.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            self.assertEqual(marker["name"], "opencode-a")
            self.assertEqual(marker["pid"], sleeper.pid)
            self.assertEqual(marker["signal"], "SIGTERM")
            self.assertEqual(marker["process_group"], sleeper_pgid)
            self.assertEqual(
                marker["reason"], "disabled snip plugin; restart managed opencode"
            )
            self.assertFalse(marker["dry_run"])
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
                try:
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    sleeper.kill()
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_opencode_self_kills_detached_child_from_snapshot(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        child_pid_path = Path(self.temp_dir.name) / "child.pid"
        parent_script = (
            "import pathlib, signal, subprocess, sys, time\n"
            f"child_pid_path = pathlib.Path({str(child_pid_path)!r})\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)\n"
            "child_pid_path.write_text(f'{child.pid}\\n', encoding='utf-8')\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
            "while True:\n"
            "    time.sleep(1)\n"
        )
        parent = subprocess.Popen(
            [sys.executable, "-c", parent_script], start_new_session=True
        )
        child_pid = None
        try:
            deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                if child_pid_path.exists():
                    child_pid = int(child_pid_path.read_text(encoding="utf-8").strip())
                    break
                time.sleep(0.05)
            self.assertIsNotNone(child_pid, "child pid file was not created")

            (config_dir / "opencode-a.pid").write_text(
                f"{parent.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"

            result = run_cli(
                "restart-opencode-self",
                "--expect-comm",
                "python",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            parent.wait(timeout=CLI_TIMEOUT_SECONDS)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if parent.poll() is None:
                parent.terminate()
                try:
                    parent.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    parent.kill()
                    parent.wait(timeout=CLI_TIMEOUT_SECONDS)
            if child_pid is not None:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_restart_opencode_self_requires_instance_name(self):
        env = dict(self.env)
        env["RUN_OPENCODE_INST_NAME"] = ""

        result = run_cli("restart-opencode-self", env=env)

        self.assertEqual(result_code(result), 2)
        self.assertIn("no instance name", result.stderr)


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
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">two</c2c>"}}\n'
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
    def test_current_session_identifier_uses_direct_parent_claude_process(self):
        def read_text(path_self):
            if str(path_self) == "/proc/4000/comm":
                return "claude\n"
            if str(path_self) == "/proc/3000/comm":
                return "bash\n"
            if str(path_self) == "/proc/5000/comm":
                return "python3\n"
            raise FileNotFoundError(str(path_self))

        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.Path.read_text", autospec=True, side_effect=read_text
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "4000")

    def test_current_session_identifier_uses_single_claude_child_of_parent_shell(self):
        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
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
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
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
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
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
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
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

    def test_summarize_transcript_ignores_onboarding_events(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"onboarding\\" from=\\"c2c-register\\" alias=\\"storm-herald\\">welcome</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"thanks"}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">hello</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CPruneUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.stale_session_id = "dead0000-0000-0000-0000-000000000000"

    def tearDown(self):
        self.temp_dir.cleanup()

    def _seed_registry(self):
        """Seed 3 registrations: agent-one, agent-two (live), and one stale."""
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                {"session_id": self.stale_session_id, "alias": "silver-banner"},
            ]
        }
        save_registry(registry, self.registry_path)
        return registry

    def _mock_load_sessions(self):
        """Return only agent-one as live; agent-two and stale are dead."""
        return [
            {"session_id": AGENT_ONE_SESSION_ID, "name": "agent-one"},
        ]

    def test_prune_removes_stale_entries_from_yaml(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main([])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(session_ids, [AGENT_ONE_SESSION_ID])

    def test_prune_dry_run_does_not_mutate(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main(["--dry-run"])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(len(session_ids), 3)
        self.assertIn(AGENT_ONE_SESSION_ID, session_ids)
        self.assertIn(AGENT_TWO_SESSION_ID, session_ids)
        self.assertIn(self.stale_session_id, session_ids)

    def test_prune_reports_removed_entries_in_json(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
            mock.patch("sys.stdout", new_callable=io.StringIO) as mock_stdout,
        ):
            rc = c2c_prune.main(["--json"])

        self.assertEqual(rc, 0)
        payload = json.loads(mock_stdout.getvalue())
        self.assertEqual(payload["count"], 2)
        self.assertFalse(payload["dry_run"])
        removed_aliases = sorted(entry["alias"] for entry in payload["pruned"])
        self.assertEqual(removed_aliases, ["ember-crown", "silver-banner"])
        removed_session_ids = sorted(entry["session_id"] for entry in payload["pruned"])
        self.assertEqual(
            removed_session_ids,
            sorted([AGENT_TWO_SESSION_ID, self.stale_session_id]),
        )


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


class C2CConfigureKimiTests(unittest.TestCase):
    def test_writes_kimi_mcp_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(mcp_path))
            self.assertTrue(mcp_path.exists())
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            c2c = config["mcpServers"]["c2c"]
            self.assertEqual(c2c["type"], "stdio")
            self.assertEqual(c2c["command"], "python3")
            self.assertEqual(c2c["args"], [str(REPO / "c2c_mcp.py")])
            self.assertEqual(c2c["env"]["C2C_MCP_BROKER_ROOT"], str(broker_root))

    def test_setup_kimi_dispatches_to_configure_kimi(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "setup",
                    "kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(mcp_path))
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcpServers"])

    def test_writes_kimi_mcp_config_with_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--session-id",
                    "kimi-test",
                    "--alias",
                    "kimi-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-test")
            self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-primary")

    def test_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            mcp_path.write_text('{"mcpServers": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            mcp_path.write_text('{"mcpServers": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])


class C2CConfigureCrushTests(unittest.TestCase):
    def test_writes_crush_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(config_path))
            self.assertTrue(config_path.exists())
            config = json.loads(config_path.read_text(encoding="utf-8"))
            c2c = config["mcp"]["c2c"]
            self.assertEqual(c2c["type"], "stdio")
            self.assertEqual(c2c["command"], "python3")
            self.assertEqual(c2c["args"], [str(REPO / "c2c_mcp.py")])
            self.assertEqual(c2c["env"]["C2C_MCP_BROKER_ROOT"], str(broker_root))

    def test_setup_crush_dispatches_to_configure_crush(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "setup",
                    "crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(config_path))
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcp"])

    def test_writes_crush_config_with_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--session-id",
                    "crush-test",
                    "--alias",
                    "crush-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "crush-test")
            self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "crush-primary")

    def test_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            config_path.write_text('{"mcp": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            config_path.write_text('{"mcp": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])

    def test_writes_default_alias_when_no_alias_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            # Default alias should be set (crush-user-host pattern)
            self.assertIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            self.assertRegex(env["C2C_MCP_AUTO_REGISTER_ALIAS"], r"^crush-.+-.+$")

    def test_no_alias_flag_suppresses_auto_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--no-alias",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)


class C2CConfigureKimiDefaultAliasTests(unittest.TestCase):
    def test_writes_default_alias_when_no_alias_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            # Default alias should be set (kimi-user-host pattern)
            self.assertIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            self.assertRegex(env["C2C_MCP_AUTO_REGISTER_ALIAS"], r"^kimi-.+-.+$")

    def test_no_alias_flag_suppresses_auto_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--no-alias",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)


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


class RunKimiInstTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.env = {}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_run_kimi_inst_dry_run_shows_launch_command(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["launch"][0], "kimi")
        self.assertEqual(payload["env"]["RUN_KIMI_INST_C2C_SESSION_ID"], "kimi-test")
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-test")

    def test_run_kimi_inst_help_exits_without_config_lookup(self):
        result = run_cli("run-kimi-inst", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-kimi-inst", result.stdout)

    def test_run_kimi_inst_outer_dry_run_reports_inner_and_rearm(self):
        env = {"RUN_KIMI_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-kimi-inst-outer", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:], [str(REPO / "run-kimi-inst"), "kimi-a"]
        )
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:], [str(REPO / "run-kimi-inst-rearm"), "kimi-a"]
        )

    def test_run_kimi_inst_outer_help_exits_without_looping(self):
        result = run_cli("run-kimi-inst-outer", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-kimi-inst-outer", result.stdout)
        self.assertNotIn("iter 1", result.stdout)

    def test_run_kimi_inst_rearm_dry_run_shows_deliver_command(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        (config_dir / "kimi-a.pid").write_text("12345\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-kimi-inst-rearm",
            "kimi-a",
            "--session-id",
            "kimi-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "kimi-a")
        self.assertEqual(payload["target_pid"], 12345)
        self.assertEqual(payload["session_id"], "kimi-a-local")
        self.assertTrue(payload["dry_run"])
        joined_commands = " ".join(
            " ".join(cmd) for cmd in payload["commands"]
        )
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id kimi-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)


class RunCrushInstTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.env = {}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_run_crush_inst_dry_run_shows_launch_command(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-test",
            "c2c_alias": "crush-test",
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["launch"][0], "crush")
        self.assertEqual(payload["env"]["RUN_CRUSH_INST_C2C_SESSION_ID"], "crush-test")
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "crush-test")

    def test_run_crush_inst_help_exits_without_config_lookup(self):
        result = run_cli("run-crush-inst", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-crush-inst", result.stdout)

    def test_run_crush_inst_outer_dry_run_reports_inner_and_rearm(self):
        env = {"RUN_CRUSH_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-crush-inst-outer", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:], [str(REPO / "run-crush-inst"), "crush-a"]
        )
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:], [str(REPO / "run-crush-inst-rearm"), "crush-a"]
        )

    def test_run_crush_inst_outer_help_exits_without_looping(self):
        result = run_cli("run-crush-inst-outer", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-crush-inst-outer", result.stdout)
        self.assertNotIn("iter 1", result.stdout)

    def test_run_crush_inst_rearm_dry_run_shows_deliver_command(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        (config_dir / "crush-a.pid").write_text("54321\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-crush-inst-rearm",
            "crush-a",
            "--session-id",
            "crush-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "crush-a")
        self.assertEqual(payload["target_pid"], 54321)
        self.assertEqual(payload["session_id"], "crush-a-local")
        self.assertTrue(payload["dry_run"])
        joined_commands = " ".join(
            " ".join(cmd) for cmd in payload["commands"]
        )
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id crush-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)


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
            payload = {"hooks": {"PostToolUse": [{"matcher": ".*", "hooks": [{"type": "command", "command": "/home/user/.claude/hooks/c2c-inbox-check.sh"}]}]}}
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


def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
