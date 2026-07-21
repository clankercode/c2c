import io
import json
import os
import runpy
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


CLI_TIMEOUT_SECONDS = 5


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


def result_code(result):
    return result.returncode


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
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)

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
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)

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
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # Session ID should equal alias so auto_register_startup works
            self.assertEqual(
                env.get("C2C_MCP_SESSION_ID"), env.get("C2C_MCP_SESSION_ID")
            )

    def test_alias_is_used_as_session_id_when_no_explicit_session(self):
        """When --alias is given but no --session-id, session ID defaults to alias."""
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
                    "--alias",
                    "crush-mybot",
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
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "crush-mybot")

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
            # No alias means no session ID either
            self.assertNotIn("C2C_MCP_SESSION_ID", env)


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
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # Session ID should equal alias so auto_register_startup works
            self.assertEqual(
                env.get("C2C_MCP_SESSION_ID"), env.get("C2C_MCP_SESSION_ID")
            )

    def test_alias_is_used_as_session_id_when_no_explicit_session(self):
        """When --alias is given but no --session-id, session ID defaults to alias."""
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
                    "--alias",
                    "kimi-mybot",
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
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-mybot")

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
            # No alias means no session ID either
            self.assertNotIn("C2C_MCP_SESSION_ID", env)

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
        # In interactive (non-print) mode, --continue is added for session resumption
        self.assertEqual(payload["launch"], ["kimi", "--yolo", "--continue"])
        self.assertEqual(payload["prompt_mode"], "interactive-cli")
        self.assertEqual(payload["env"]["RUN_KIMI_INST_C2C_SESSION_ID"], "kimi-test")
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-test")
        # C2C_MCP_CLIENT_PID must be set so broker registers against durable Kimi PID
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")

    def test_run_kimi_inst_dry_run_supports_command_array(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": ["uvx", "--python", "python3.14", "--from", "kimi-cli", "kimi"],
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
        # In interactive (non-print) mode, --continue is added for session resumption
        self.assertEqual(
            payload["launch"],
            [
                "uvx",
                "--python",
                "python3.14",
                "--from",
                "kimi-cli",
                "kimi",
                "--yolo",
                "--continue",
            ],
        )

    def test_run_kimi_inst_dry_run_uses_captured_session_sidecar(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        (config_dir / "kimi-a.session.json").write_text(
            json.dumps({"kimi_session_id": "captured-kimi-session"}),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"],
            ["kimi", "--yolo", "--session", "captured-kimi-session"],
        )

    def test_run_kimi_inst_dry_run_prefills_prompt_in_interactive_mode(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        bin_dir = Path(self.temp_dir.name) / "bin"
        bin_dir.mkdir()
        kimi_python = Path(self.temp_dir.name) / "kimi-python"
        kimi_python.write_text("#!/bin/sh\n", encoding="utf-8")
        kimi_python.chmod(0o755)
        kimi = bin_dir / "kimi"
        kimi.write_text(f"#!{kimi_python}\n", encoding="utf-8")
        kimi.chmod(0o755)
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
            "prompt": "poll inbox",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)
        env["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"],
            [
                str(kimi_python),
                str(REPO / "c2c_kimi_prefill.py"),
                "--yolo",
                "--continue",
                "--prompt",
                "poll inbox",
            ],
        )
        self.assertEqual(payload["interactive_prompt"], "prefill")
        self.assertNotIn("--trust-all-tools", payload["launch"])
        self.assertNotIn("--print", payload["launch"])
        self.assertEqual(payload["prompt_mode"], "interactive-prefill")

    def test_run_kimi_inst_dry_run_uses_print_mode_when_explicitly_configured(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
            "prompt": "poll inbox",
            "print": True,
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"][:5],
            ["kimi", "--yolo", "--print", "--prompt", "poll inbox"],
        )
        self.assertEqual(payload["prompt_mode"], "non-interactive")

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
        self.assertEqual(payload["inner"][1:], [str(REPO / "run-kimi-inst"), "kimi-a"])
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:], [str(REPO / "run-kimi-inst-rearm"), "kimi-a"]
        )
        self.assertFalse(payload["start_new_session"])

    def test_run_kimi_inst_outer_help_exits_without_looping(self):
        result = run_cli("run-kimi-inst-outer", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-kimi-inst-outer", result.stdout)
        self.assertNotIn("iter 1", result.stdout)

    def test_run_kimi_inst_outer_refresh_peer_passes_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "kimi-a.json").write_text(
            json.dumps({"c2c_alias": "kimi-nova", "c2c_session_id": "kimi-session"}),
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
            namespace["maybe_refresh_peer"]("kimi-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0],
            [
                sys.executable,
                str(refresh),
                "kimi-nova",
                "--pid",
                "12345",
                "--session-id",
                "kimi-session",
            ],
        )

    def test_run_kimi_inst_outer_refresh_peer_passes_env_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "kimi-b.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "kimi-nova",
                    "env": {"C2C_MCP_SESSION_ID": "kimi-env-session"},
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
            namespace["maybe_refresh_peer"]("kimi-b", 12345)

        self.assertEqual(len(calls), 1)
        self.assertIn("--session-id", calls[0])
        idx = calls[0].index("--session-id")
        self.assertEqual(calls[0][idx + 1], "kimi-env-session")

    def test_run_kimi_inst_outer_refresh_peer_prefers_wire_daemon_pid(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "kimi-c.json").write_text(
            json.dumps({"c2c_alias": "kimi-nova-2", "c2c_session_id": "kimi-nova"}),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        globals_for_outer = namespace["maybe_refresh_peer"].__globals__
        globals_for_outer["HERE"] = root
        globals_for_outer["_running_wire_daemon_pid"] = lambda session_id: 54321

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("kimi-c", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("--pid") + 1], "54321")

    def test_run_kimi_inst_outer_captures_session_to_ignored_sidecar(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name) / "repo"
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir(parents=True)
        work_dir = Path(self.temp_dir.name) / "work"
        work_dir.mkdir()
        cfg_path = cfg_dir / "kimi-a.json"
        cfg_path.write_text(json.dumps({"cwd": str(work_dir)}), encoding="utf-8")
        home = Path(self.temp_dir.name) / "home"
        session_state = home / ".kimi" / "sessions" / "captured-session" / "state.json"
        session_state.parent.mkdir(parents=True)
        session_state.write_text(json.dumps({"archived": False}), encoding="utf-8")
        kimi_json = home / ".kimi" / "kimi.json"
        kimi_json.write_text(
            json.dumps(
                {
                    "work_dirs": [
                        {
                            "path": str(work_dir),
                            "last_session_id": "captured-session",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        globals_for_outer = namespace["_capture_kimi_session"].__globals__
        globals_for_outer["HERE"] = root

        with (
            mock.patch.dict(os.environ, {"HOME": str(home)}),
            mock.patch.object(globals_for_outer["time"], "sleep", lambda _seconds: None),
        ):
            namespace["_capture_kimi_session"]("kimi-a")

        self.assertEqual(json.loads(cfg_path.read_text(encoding="utf-8")), {"cwd": str(work_dir)})
        self.assertEqual(
            json.loads((cfg_dir / "kimi-a.session.json").read_text(encoding="utf-8")),
            {"kimi_session_id": "captured-session"},
        )

    def test_run_kimi_inst_outer_logs_rearm_output(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        rearm = root / "run-kimi-inst-rearm"
        rearm.write_text("#!/bin/sh\n", encoding="utf-8")
        globals_for_outer = namespace["maybe_rearm"].__globals__
        globals_for_outer["HERE"] = root
        globals_for_outer["REARM"] = rearm

        def fake_run(command, *, cwd, check, stdout, stderr):
            stdout.write("rearm stdout\n")
            stderr.write("rearm stderr\n")
            return subprocess.CompletedProcess(command, 9)

        with (
            mock.patch.dict(os.environ, {"RUN_KIMI_INST_REARM": "1"}),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            namespace["maybe_rearm"]("kimi-a")

        log_path = root / "run-kimi-inst.d" / "kimi-a.outer.log"
        self.assertEqual(
            log_path.read_text(encoding="utf-8"), "rearm stdout\nrearm stderr\n"
        )
        self.assertIn("rearm exited code=9", stderr.getvalue())
        self.assertIn(str(log_path), stderr.getvalue())

    def test_run_kimi_inst_rearm_dry_run_shows_deliver_command(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        live_pid = os.getpid()
        (config_dir / "kimi-a.pid").write_text(f"{live_pid}\n", encoding="utf-8")
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
        self.assertEqual(payload["target_pid"], live_pid)
        self.assertEqual(payload["target_source"], "pidfile")
        self.assertEqual(payload["session_id"], "kimi-a-local")
        self.assertTrue(payload["dry_run"])
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id kimi-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)

    def test_run_kimi_inst_rearm_uses_live_broker_pid_when_pidfile_stale(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        broker_root = Path(self.temp_dir.name) / "broker"
        config_dir.mkdir()
        broker_root.mkdir()
        (config_dir / "kimi-nova.pid").write_text("11111\n", encoding="utf-8")
        config = {
            "c2c_session_id": "kimi-nova",
            "c2c_alias": "kimi-nova",
        }
        (config_dir / "kimi-nova.json").write_text(json.dumps(config), encoding="utf-8")
        live_pid = os.getpid()
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": "kimi-nova",
                        "alias": "kimi-nova",
                        "pid": live_pid,
                        "pid_start_time": c2c_mcp.read_pid_start_time(live_pid),
                    }
                ]
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)

        result = run_cli(
            "run-kimi-inst-rearm",
            "kimi-nova",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["target_pid"], live_pid)
        self.assertEqual(payload["target_source"], "broker")
        self.assertEqual(payload["pidfile_pid"], 11111)
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn(f"--pid {live_pid}", joined_commands)


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

    def test_run_crush_inst_uses_explicit_crush_session_id(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-c2c",
            "c2c_alias": "crush-c2c",
            "crush_session_id": "crush-native-session",
            "flags": ["--model", "sonnet", "--continue", "-C"],
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"],
            ["crush", "--model", "sonnet", "-s", "crush-native-session"],
        )
        self.assertNotIn("--continue", payload["launch"])
        self.assertNotIn("-C", payload["launch"])

    def test_run_crush_inst_crush_session_id_must_be_string(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-c2c",
            "crush_session_id": 123,
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertNotEqual(result_code(result), 0)
        self.assertIn("crush_session_id must be a string", result.stderr)

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

    def test_run_crush_inst_outer_create_writes_default_config(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-crush-inst"
        rearm = root / "run-crush-inst-rearm"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        rearm.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner
        namespace["main"].__globals__["REARM"] = rearm

        stdout = io.StringIO()
        with (
            mock.patch.dict(
                os.environ, {"RUN_CRUSH_INST_OUTER_DRY_RUN": "1"}, clear=False
            ),
            mock.patch("sys.stdout", new=stdout),
        ):
            rc = namespace["main"](["run-crush-inst-outer", "--create", "crush-new"])

        self.assertEqual(rc, 0)
        cfg_path = root / "run-crush-inst.d" / "crush-new.json"
        self.assertTrue(cfg_path.exists())
        payload = json.loads(cfg_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["command"], "crush")
        self.assertEqual(payload["cwd"], str(root))
        self.assertEqual(payload["c2c_session_id"], "crush-new")
        self.assertEqual(payload["c2c_alias"], "crush-new")
        self.assertIn("[run-crush-inst-outer] created config:", stdout.getvalue())

    def test_run_crush_inst_outer_create_preserves_existing_config(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-crush-inst.d"
        cfg_dir.mkdir()
        cfg_path = cfg_dir / "crush-existing.json"
        cfg_path.write_text(
            json.dumps({"command": "custom-crush", "c2c_alias": "stable"}),
            encoding="utf-8",
        )
        namespace["_create_config"].__globals__["HERE"] = root

        result = namespace["_create_config"]("crush-existing")

        self.assertEqual(result, cfg_path)
        self.assertEqual(
            json.loads(cfg_path.read_text(encoding="utf-8")),
            {"command": "custom-crush", "c2c_alias": "stable"},
        )

    def test_run_crush_inst_outer_refreshes_peer_after_child_spawn(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-crush-inst"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner

        refresh_calls = []

        class FakeProcess:
            pid = 43210
            returncode = 0

            def poll(self):
                return self.returncode

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
                namespace["main"](["run-crush-inst-outer", "crush-a"])

        self.assertEqual(refresh_calls, [("crush-a", 43210)])

    def test_run_crush_inst_outer_refresh_peer_passes_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-crush-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "crush-a.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "crush-primary",
                    "c2c_session_id": "crush-session",
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
            namespace["maybe_refresh_peer"]("crush-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0],
            [
                sys.executable,
                str(refresh),
                "crush-primary",
                "--pid",
                "12345",
                "--session-id",
                "crush-session",
            ],
        )

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
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id crush-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)


if __name__ == "__main__":
    unittest.main()
