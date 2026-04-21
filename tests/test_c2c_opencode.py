import io
import json
import os
import signal
import shutil
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


class OpenCodeLocalConfigTests(unittest.TestCase):
    def test_opencode_local_config_exposes_c2c_mcp(self):
        config = json.loads(
            (REPO / ".opencode" / "opencode.json").read_text(encoding="utf-8")
        )
        c2c = config["mcp"]["c2c"]
        self.assertEqual(c2c["type"], "local")
        # Accept any launcher that ultimately runs the c2c MCP server:
        # installed binary ("c2c-mcp-server"), python wrapper ("python3"),
        # opam exec wrapper ("opam"), or a direct path.
        cmd = c2c["command"]
        self.assertIsInstance(cmd, list)
        self.assertGreater(len(cmd), 0)
        valid_launchers = {"c2c-mcp-server", "python3", "opam"}
        cmd_str = " ".join(cmd)
        self.assertTrue(
            cmd[0] in valid_launchers or "c2c_mcp_server" in cmd_str or "c2c_mcp.py" in cmd_str,
            f"MCP command {cmd!r} doesn't look like a c2c MCP server invocation"
        )
        env = c2c.get("environment", {})
        # Must configure the swarm-lounge auto-join
        self.assertEqual(env.get("C2C_MCP_AUTO_JOIN_ROOMS"), "swarm-lounge")
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
        self.assertIn("OPENCODE_MCP_PROMPT", payload["env"])
        self.assertEqual(payload["env"]["C2C_MCP_SESSION_ID"], "opencode-local")
        self.assertEqual(
            payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-local"
        )
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        self.assertEqual(
            payload["env"]["C2C_MCP_BROKER_ROOT"],
            str(REPO / ".git" / "c2c" / "mcp"),
        )
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_RESTART_MARKER"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.restart.json"),
        )

    def test_run_opencode_inst_silent_suppresses_wrapper_stderr(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            project = Path(temp_dir) / "repo"
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            project.mkdir()
            config_dir.mkdir()
            opencode_config = config_dir / "opencode-a.opencode.json"
            opencode_config.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            (config_dir / "opencode-a.json").write_text(
                json.dumps(
                    {
                        "command": sys.executable,
                        "cwd": str(project),
                        "config_path": str(opencode_config),
                        "c2c_session_id": "opencode-a-local",
                        "c2c_alias": "opencode-a",
                        "prompt": "poll inbox",
                        "flags": ["-c", "import sys; sys.exit(0)"],
                    }
                ),
                encoding="utf-8",
            )

            result = run_cli(
                "run-opencode-inst",
                "opencode-a",
                env={
                    "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                    "RUN_OPENCODE_INST_SILENT": "1",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

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
                root = Path(temp_dir)
                config_dir = root / "run-opencode-inst.d"
                config_dir.mkdir()
                broker_root = root / "mcp-broker"
                broker_root.mkdir()
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
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }

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

    def test_run_opencode_inst_rearm_refreshes_broker_registration_before_tty_skip(
        self,
    ):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                config_dir = root / "run-opencode-inst.d"
                config_dir.mkdir()
                broker_root = root / "mcp-broker"
                broker_root.mkdir()
                (broker_root / "registry.json").write_text(
                    json.dumps(
                        [
                            {
                                "session_id": "opencode-a-local",
                                "alias": "opencode-a",
                                "pid": 99999999,
                            }
                        ]
                    ),
                    encoding="utf-8",
                )
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
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }

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
                registrations = json.loads(
                    (broker_root / "registry.json").read_text(encoding="utf-8")
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
        self.assertTrue(payload["registration"]["ok"])
        self.assertEqual(payload["registration"]["pid"], sleeper.pid)
        self.assertEqual(registrations[0]["alias"], "opencode-a")
        self.assertEqual(registrations[0]["session_id"], "opencode-a-local")
        self.assertEqual(registrations[0]["pid"], sleeper.pid)
        self.assertIsInstance(registrations[0]["pid_start_time"], int)

    def test_run_opencode_inst_rearm_refreshes_plugin_sidecar_before_tty_skip(self):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                project = root / "project"
                config_dir = root / "run-opencode-inst.d"
                broker_root = root / "mcp-broker"
                (project / ".opencode").mkdir(parents=True)
                config_dir.mkdir()
                broker_root.mkdir()
                sidecar_path = project / ".opencode" / "c2c-plugin.json"
                sidecar_path.write_text(
                    json.dumps(
                        {
                            "session_id": "stale-session",
                            "alias": "stale-alias",
                            "broker_root": "/stale/broker",
                        }
                    ),
                    encoding="utf-8",
                )
                (config_dir / "opencode-a.json").write_text(
                    json.dumps(
                        {
                            "cwd": str(project),
                            "session": "ses_managed_opencode",
                            "c2c_session_id": "opencode-a-local",
                            "c2c_alias": "opencode-a",
                        }
                    ),
                    encoding="utf-8",
                )
                env = {
                    "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }

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
                sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=1)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=1)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sidecar["session_id"], "opencode-a-local")
        self.assertEqual(sidecar["alias"], "opencode-a")
        self.assertEqual(sidecar["broker_root"], str(broker_root))
        self.assertEqual(sidecar["opencode_session_id"], "ses_managed_opencode")

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

    def test_run_opencode_inst_dry_run_does_not_overwrite_plugin_sidecar(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode").mkdir(parents=True)
            config_dir.mkdir()
            existing_sidecar = {
                "session_id": "live-session",
                "alias": "live-alias",
                "broker_root": "/live/broker",
            }
            sidecar_path = project / ".opencode" / "c2c-plugin.json"
            sidecar_path.write_text(
                json.dumps(existing_sidecar, indent=2) + "\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "dry-run.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": "opencode",
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "dry-run-session",
                "c2c_alias": "dry-run-alias",
                "prompt": "test prompt",
            }
            (config_dir / "dry-run.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_DRY_RUN": "1",
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "dry-run", env=env)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(sidecar_path.read_text(encoding="utf-8")),
                existing_sidecar,
            )

    def test_run_opencode_inst_copies_plugin_to_config_dir(self):
        """_ensure_opencode_plugin copies plugin + package.json when config is outside .opencode/."""
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")
        with tempfile.TemporaryDirectory() as temp_dir:
            project = Path(temp_dir) / "repo"
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                plugin_src.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (project / ".opencode" / "package.json").write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "1.4.3"}}),
                encoding="utf-8",
            )
            (project / ".opencode" / "node_modules").mkdir()
            opencode_json = config_dir / "test-inst.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "test-inst",
                "c2c_alias": "test-inst",
                "prompt": "test",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "test-inst.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "test-inst", env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Plugin should have been synced to the config dir's plugins/
            plugin_dest = config_dir / "plugins" / "c2c.ts"
            pkg_dest = config_dir / "package.json"
            self.assertTrue(
                plugin_dest.exists(), "plugin should be copied to config dir"
            )
            self.assertTrue(
                pkg_dest.exists(), "package.json should be copied to config dir"
            )
            # node_modules symlink should be created so Bun can resolve @opencode-ai/plugin
            nm_src = project / ".opencode" / "node_modules"
            nm_dest = config_dir / "node_modules"
            if nm_src.exists():
                self.assertTrue(
                    nm_dest.is_symlink(), "node_modules should be a symlink"
                )
                self.assertEqual(
                    os.readlink(str(nm_dest)),
                    str(nm_src),
                    "node_modules symlink should point to .opencode/node_modules",
                )

    def test_run_opencode_inst_writes_plugin_sidecar_in_cwd(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            (project / ".opencode" / "package.json").write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "1.4.3"}}),
                encoding="utf-8",
            )
            opencode_json = config_dir / "opencode-local.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-local",
                "c2c_alias": "opencode-local",
                "session": "ses_managed_opencode",
                "prompt": "test",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "opencode-local.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "opencode-local", env=env)

            self.assertEqual(result.returncode, 0, result.stderr)
            sidecar = json.loads(
                (project / ".opencode" / "c2c-plugin.json").read_text(encoding="utf-8")
            )
            self.assertEqual(sidecar["session_id"], "opencode-local")
            self.assertEqual(sidecar["alias"], "opencode-local")
            self.assertEqual(sidecar["opencode_session_id"], "ses_managed_opencode")
            self.assertEqual(
                sidecar["broker_root"], str(project / ".git" / "c2c" / "mcp")
            )

    def test_run_opencode_inst_injects_spool_into_prompt(self):
        """Spooled messages (failed promptAsync) are prepended to the next startup prompt."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "spool-test.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-spool",
                "c2c_alias": "opencode-spool",
                "prompt": "STEP 1: poll inbox",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "spool-test.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            # Write a spool file simulating a failed promptAsync from last cycle
            spool = [
                {
                    "from_alias": "storm-beacon",
                    "to_alias": "opencode-spool",
                    "content": "hi from spool",
                }
            ]
            spool_path = project / ".opencode" / "c2c-plugin-spool.json"
            spool_path.write_text(json.dumps(spool), encoding="utf-8")

            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                "RUN_OPENCODE_INST_DRY_RUN": "1",
            }
            result = run_cli("run-opencode-inst", "spool-test", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            effective_prompt = payload["env"]["OPENCODE_MCP_PROMPT"]
            # Spool message must appear before the normal prompt text
            self.assertIn("hi from spool", effective_prompt)
            self.assertIn('from="storm-beacon"', effective_prompt)
            self.assertIn('source="spool"', effective_prompt)
            self.assertIn("STEP 1: poll inbox", effective_prompt)
            spool_pos = effective_prompt.index("hi from spool")
            step_pos = effective_prompt.index("STEP 1: poll inbox")
            self.assertLess(spool_pos, step_pos, "spool must come before normal prompt")
            # In dry-run, spool must NOT be cleared
            self.assertEqual(json.loads(spool_path.read_text(encoding="utf-8")), spool)

    def test_run_opencode_inst_clears_spool_in_live_run(self):
        """Spool file is cleared after injection (apply_side_effects=True in non-dry-run)."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "spool-clear.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-spool-clear",
                "c2c_alias": "opencode-spool-clear",
                "prompt": "poll inbox",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "spool-clear.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            spool = [
                {
                    "from_alias": "codex",
                    "to_alias": "opencode-spool-clear",
                    "content": "clear me",
                }
            ]
            spool_path = project / ".opencode" / "c2c-plugin-spool.json"
            spool_path.write_text(json.dumps(spool), encoding="utf-8")

            env = {"RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)}
            result = run_cli("run-opencode-inst", "spool-clear", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            # Spool must be cleared after live run
            remaining = json.loads(spool_path.read_text(encoding="utf-8"))
            self.assertEqual(remaining, [], "spool should be empty after live run")

    def test_opencode_plugin_uses_supported_process_runner_for_drain(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertNotIn("ctx.$.quiet", plugin_text)
        self.assertIn('from "child_process"', plugin_text)
        self.assertIn("spawn(", plugin_text)

    def test_opencode_plugin_starts_background_loop_without_lifecycle_hook(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertIn("function startBackgroundLoop()", plugin_text)
        self.assertIn("startBackgroundLoop();", plugin_text)

    def test_opencode_plugin_prefers_configured_session_target(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertIn("sidecar.opencode_session_id", plugin_text)
        self.assertIn("configuredOpenCodeSessionId", plugin_text)
        self.assertIn(
            "let activeSessionId: string | null = configuredOpenCodeSessionId",
            plugin_text,
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
        self.assertTrue(
            "c2c_mcp.py" in result.stdout
            or "c2c-mcp-server" in result.stdout
            or "c2c_mcp_server" in result.stdout,
            f"no c2c MCP server invocation found in: {result.stdout}",
        )


class RunOpenCodeInstPluginTests(unittest.TestCase):
    def _make_config(
        self, config_dir: Path, name: str, cwd: Path, config_path: Path
    ) -> Path:
        config = {
            "command": sys.executable,
            "cwd": str(cwd),
            "config_path": str(config_path),
            "c2c_session_id": f"{name}-local",
            "c2c_alias": name,
            "prompt": "poll inbox",
            "flags": ["-c", "import sys; sys.exit(0)"],
        }
        config_file = config_dir / f"{name}.json"
        config_file.write_text(json.dumps(config), encoding="utf-8")
        return config_file

    def test_copies_plugin_when_config_outside_repo_opencode(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "^1.0.0"}}),
                encoding="utf-8",
            )
            nm_src = opencode_dir / "node_modules"
            nm_src.mkdir()

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertTrue(
                plugin_dest.exists(), f"plugin should be copied to {plugin_dest}"
            )
            self.assertEqual(plugin_dest.read_text(encoding="utf-8"), "// plugin")
            pkg_dest = config_dir / "package.json"
            self.assertTrue(pkg_dest.exists())
            pkg = json.loads(pkg_dest.read_text(encoding="utf-8"))
            self.assertEqual(pkg["dependencies"]["@opencode-ai/plugin"], "^1.0.0")
            nm_dest = config_dir / "node_modules"
            self.assertTrue(nm_dest.is_symlink() or nm_dest.exists())

    def test_skips_plugin_copy_when_config_inside_repo_opencode(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "^1.0.0"}}),
                encoding="utf-8",
            )
            nm_src = opencode_dir / "node_modules"
            nm_src.mkdir()

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = opencode_dir / "opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertFalse(
                plugin_dest.exists(),
                "plugin should NOT be copied when config is inside repo .opencode",
            )
            pkg_dest = config_dir / "package.json"
            self.assertFalse(
                pkg_dest.exists() or pkg_dest.is_symlink(),
                "package.json should NOT be copied",
            )
            nm_dest = config_dir / "node_modules"
            self.assertFalse(
                nm_dest.exists() or nm_dest.is_symlink(),
                "node_modules should NOT be symlinked",
            )

    def test_merges_package_json_when_already_exists_in_config_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps(
                    {
                        "dependencies": {
                            "@opencode-ai/plugin": "^1.0.0",
                            "new-dep": "^2.0.0",
                        }
                    }
                ),
                encoding="utf-8",
            )

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            existing_pkg = config_dir / "package.json"
            existing_pkg.write_text(
                json.dumps({"dependencies": {"existing-dep": "^0.1.0"}}),
                encoding="utf-8",
            )
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            pkg = json.loads(existing_pkg.read_text(encoding="utf-8"))
            self.assertEqual(pkg["dependencies"]["existing-dep"], "^0.1.0")
            self.assertEqual(pkg["dependencies"]["@opencode-ai/plugin"], "^1.0.0")
            self.assertEqual(pkg["dependencies"]["new-dep"], "^2.0.0")

    def test_no_op_when_plugin_source_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            # no plugins/c2c.ts

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertFalse(plugin_dest.exists())


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
            self.assertIn(c2c["command"][0], ["c2c-mcp-server", "python3"])
            self.assertEqual(
                c2c["environment"]["C2C_MCP_BROKER_ROOT"],
                str(REPO / ".git" / "c2c" / "mcp"),
            )
            self.assertEqual(
                c2c["environment"]["C2C_MCP_SESSION_ID"],
                f"opencode-{target.name}",
            )
            self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
            self.assertEqual(
                c2c["environment"]["C2C_MCP_AUTO_REGISTER_ALIAS"],
                f"opencode-{target.name}",
            )
            self.assertEqual(
                c2c["environment"]["C2C_MCP_AUTO_JOIN_ROOMS"],
                "swarm-lounge",
            )
            self.assertTrue(c2c["enabled"])
            self.assertEqual(payload["session_id"], f"opencode-{target.name}")
            self.assertEqual(payload["alias"], f"opencode-{target.name}")
            sidecar_path = target / ".opencode" / "c2c-plugin.json"
            self.assertTrue(sidecar_path.exists())
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            self.assertEqual(sidecar["session_id"], f"opencode-{target.name}")
            self.assertEqual(sidecar["alias"], f"opencode-{target.name}")
            self.assertEqual(sidecar["broker_root"], str(REPO / ".git" / "c2c" / "mcp"))
            self.assertTrue((target / ".opencode" / "plugins" / "c2c.ts").exists())
            package_json = json.loads(
                (target / ".opencode" / "package.json").read_text(encoding="utf-8")
            )
            self.assertIn("@opencode-ai/plugin", package_json["dependencies"])

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
            sidecar = json.loads(
                (target / ".opencode" / "c2c-plugin.json").read_text(encoding="utf-8")
            )
            self.assertEqual(sidecar["session_id"], f"opencode-{target.name}")
            self.assertEqual(sidecar["alias"], "opencode-primary")

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


if __name__ == "__main__":
    unittest.main()
