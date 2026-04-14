import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_poker


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


class C2CLegacyManagedRunnerTests(unittest.TestCase):
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
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        # Remove the dynamic PID override before checking the rest of launch
        launch = payload["launch"]
        pid_override = f'mcp_servers.c2c.env.C2C_MCP_CLIENT_PID="{payload["env"]["C2C_MCP_CLIENT_PID"]}"'
        if pid_override in launch:
            idx = launch.index(pid_override)
            launch = (
                launch[: idx - 1] + launch[idx + 1 :]
            )  # remove the preceding "-c" too
        self.assertEqual(
            launch,
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
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        # Remove the dynamic PID override before checking the rest of launch
        launch = payload["launch"]
        pid_override = f'mcp_servers.c2c.env.C2C_MCP_CLIENT_PID="{payload["env"]["C2C_MCP_CLIENT_PID"]}"'
        if pid_override in launch:
            idx = launch.index(pid_override)
            launch = (
                launch[: idx - 1] + launch[idx + 1 :]
            )  # remove the preceding "-c" too
        self.assertEqual(
            launch,
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

    def test_run_claude_inst_outer_refreshes_peer_after_child_spawn(self):
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-claude-inst"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner

        refresh_calls = []

        class FakeProcess:
            pid = 43210

            def wait(self):
                return 0

        namespace["main"].__globals__["maybe_refresh_peer"] = lambda name, pid: (
            refresh_calls.append((name, pid))
        )

        with (
            mock.patch("subprocess.Popen", return_value=FakeProcess()),
            mock.patch(
                "subprocess.run", return_value=subprocess.CompletedProcess([], 0)
            ),
            mock.patch("time.sleep", side_effect=KeyboardInterrupt),
        ):
            with self.assertRaises(KeyboardInterrupt):
                namespace["main"](["run-claude-inst-outer", "claude-a"])

        self.assertEqual(refresh_calls, [("claude-a", 43210)])

    def test_run_claude_inst_outer_refresh_peer_uses_config_alias(self):
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        # Config with top-level c2c_session_id; refresh-peer gets --session-id.
        (cfg_dir / "claude-a.json").write_text(
            json.dumps({"c2c_alias": "storm-beacon", "c2c_session_id": "sid-abc"}),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(
                {
                    "command": command,
                    "cwd": cwd,
                    "capture_output": capture_output,
                    "text": text,
                    "timeout": timeout,
                }
            )
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0]["command"],
            [
                sys.executable,
                str(refresh),
                "storm-beacon",
                "--pid",
                "12345",
                "--session-id",
                "sid-abc",
            ],
        )
        self.assertEqual(calls[0]["cwd"], root)
        self.assertTrue(calls[0]["capture_output"])
        self.assertTrue(calls[0]["text"])
        self.assertEqual(calls[0]["timeout"], 5.0)

    def test_run_claude_inst_outer_refresh_peer_passes_env_session_id(self):
        """Claude instances store session_id in env.C2C_MCP_SESSION_ID; outer loop passes it."""
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        # Claude format: session_id is in env dict, not top-level
        (cfg_dir / "claude-b.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "storm-beacon",
                    "env": {
                        "C2C_MCP_SESSION_ID": "d16034fc-5526-414b-a88e-709d1a93e345"
                    },
                }
            ),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-b", 12345)

        self.assertEqual(len(calls), 1)
        self.assertIn("--session-id", calls[0])
        idx = calls[0].index("--session-id")
        self.assertEqual(calls[0][idx + 1], "d16034fc-5526-414b-a88e-709d1a93e345")

    def test_run_claude_inst_outer_refresh_peer_no_session_id_in_config(self):
        """When config has no session_id, --session-id is not passed."""
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "claude-c.json").write_text(
            json.dumps({"c2c_alias": "storm-beacon"}),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-c", 12345)

        self.assertEqual(len(calls), 1)
        self.assertNotIn("--session-id", calls[0])

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

if __name__ == "__main__":
    unittest.main()
