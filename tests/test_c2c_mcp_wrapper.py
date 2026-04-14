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

import c2c_mcp
from c2c_registry import save_registry


CLI_TIMEOUT_SECONDS = 5
AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


class C2CMCPWrapperTests(unittest.TestCase):
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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
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
            mock.patch.dict(
                os.environ,
                {"C2C_MCP_SESSION_ID": "", "C2C_MCP_CLIENT_PID": ""},
                clear=False,
            ),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
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

    def test_c2c_mcp_main_replaces_dead_client_pid_env_for_server_register(self):
        with (
            mock.patch.dict(
                os.environ,
                {"C2C_MCP_SESSION_ID": "", "C2C_MCP_CLIENT_PID": "11111"},
                clear=False,
            ),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.os.path.exists", return_value=False),
            mock.patch("c2c_mcp.os.getppid", return_value=424242),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_SESSION_ID"], AGENT_ONE_SESSION_ID)
        self.assertEqual(env["C2C_MCP_CLIENT_PID"], "424242")

    def test_c2c_mcp_auto_register_ignores_dead_client_pid_env(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        live_parent_pid = os.getpid()
        env = {
            "C2C_MCP_BROKER_ROOT": str(broker_root),
            "C2C_MCP_SESSION_ID": "kimi-nova",
            "C2C_MCP_AUTO_REGISTER_ALIAS": "kimi-nova",
            "C2C_MCP_CLIENT_PID": "11111",
        }

        with (
            mock.patch("c2c_mcp._session_pid_from_proc", return_value=None),
            mock.patch("c2c_mcp.os.getppid", return_value=live_parent_pid),
        ):
            c2c_mcp.maybe_auto_register_startup(env)

        registrations = c2c_mcp.load_broker_registrations(broker_root / "registry.json")
        self.assertEqual(len(registrations), 1)
        self.assertEqual(registrations[0]["alias"], "kimi-nova")
        self.assertEqual(registrations[0]["pid"], live_parent_pid)
        self.assertEqual(
            registrations[0]["pid_start_time"],
            c2c_mcp.read_pid_start_time(live_parent_pid),
        )

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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
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

    def test_c2c_mcp_main_falls_back_to_existing_binary_when_build_fails(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = Path(self.temp_dir.name) / "c2c_mcp_server.exe"
        built_server.write_text("#!/bin/sh\n", encoding="utf-8")

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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            run_mock.side_effect = [
                subprocess.CalledProcessError(2, ["dune", "build"]),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].args[0], [str(built_server), "--help"]
        )
        self.assertIn("build failed but existing binary found", stderr.getvalue())
        self.assertIn(str(built_server), stderr.getvalue())

    def test_c2c_mcp_main_falls_back_to_existing_binary_when_build_times_out(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = Path(self.temp_dir.name) / "c2c_mcp_server.exe"
        built_server.write_text("#!/bin/sh\n", encoding="utf-8")

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
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.BUILD_SERVER_TIMEOUT_SECONDS", 0.01),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            run_mock.side_effect = [
                subprocess.TimeoutExpired(["dune", "build"], 0.01),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].args[0], [str(built_server), "--help"]
        )
        self.assertEqual(run_mock.call_args_list[0].kwargs["timeout"], 0.01)
        self.assertIn("build timed out but existing binary found", stderr.getvalue())

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
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = "storm-ember"
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

if __name__ == "__main__":
    unittest.main()
