import io
import json
import os
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
import c2c_mcp
import c2c_poll_inbox
import c2c_poker
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
        "c2c-register",
        "c2c-list",
        "c2c-send",
        "c2c-install",
        "c2c-verify",
        "c2c-whoami",
        "c2c_register.py",
        "c2c_list.py",
        "c2c_send.py",
        "c2c_install.py",
        "c2c_verify.py",
        "c2c_whoami.py",
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
                "c2c-install",
                "c2c-list",
                "c2c-register",
                "c2c-send",
                "c2c-verify",
                "c2c-whoami",
            ],
        )
        self.assertTrue((install_dir / "c2c").exists())
        self.assertTrue((install_dir / "c2c-register").exists())
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
            mock.patch("c2c_mcp.time.monotonic", side_effect=[100.0, 100.5, 102.1]),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            with self.assertRaisesRegex(ValueError, "session not found: 11111"):
                c2c_mcp.default_session_id()

        self.assertEqual(load_mock.call_count, 2)
        sleep_mock.assert_called_once_with(
            c2c_mcp.SESSION_DISCOVERY_POLL_INTERVAL_SECONDS
        )

    def test_c2c_mcp_main_skips_session_env_when_current_session_unresolvable(self):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
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
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], str(REPO / ".git" / "c2c" / "mcp"))
        self.assertNotIn("C2C_MCP_SESSION_ID", env)

    def test_c2c_mcp_main_exports_current_client_pid_for_server_register(self):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.os.getpid", return_value=424242),
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
        self.assertEqual(payload["result"]["content"][0]["text"], "queued")
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
        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {
                    "session_id": AGENT_ONE_SESSION_ID,
                    "alias": payload["alias"],
                }
            ],
        )

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
                "c2c-register",
                "c2c-list",
                "c2c-send",
                "c2c-install",
                "c2c-verify",
                "c2c-whoami",
                "c2c_register.py",
                "c2c_list.py",
                "c2c_send.py",
                "c2c_install.py",
                "c2c_verify.py",
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

    def test_list_sessions_includes_alias_for_registered_live_sessions(self):
        sessions = [
            {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID},
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        def mutate_registry(mutator):
            mutator(registry)
            return registry

        with (
            mock.patch("c2c_list.load_sessions", return_value=sessions),
            mock.patch("c2c_list.update_registry", side_effect=mutate_registry),
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
                {"C2C_SESSION_ID": AGENT_ONE_SESSION_ID},
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
    def test_render_payload_wraps_plain_message_in_single_c2c_root_with_metadata(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="agent-one",
                sender_alias="storm-herald",
            ),
            '<c2c event="message" from="agent-one" alias="storm-herald">\nhello peer\n</c2c>',
        )

    def test_render_payload_omits_alias_when_sender_alias_missing(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="c2c-send",
                sender_alias="",
            ),
            '<c2c event="message" from="c2c-send">\nhello peer\n</c2c>',
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
            '<c2c event="message" from="c2c-send">\nhello peer\n</c2c>',
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
            '<c2c event="message" from="c2c-send">\nhello peer\n</c2c>',
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
            '<c2c event="message" from="c2c-send">\nhello peer\n</c2c>',
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
            '<c2c event="message" from="c2c-send">\nhello peer\n</c2c>',
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
            mock.patch.dict(os.environ, {}, clear=False),
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


def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
