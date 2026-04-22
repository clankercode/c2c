import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from tests.conftest import clean_c2c_start_env, spawn_tracked

CLI_EXE = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"
CLI_TIMEOUT = 10.0
_CLI_BUILT = CLI_EXE.exists()
_CLI_SKIP = unittest.skipUnless(_CLI_BUILT, "OCaml CLI binary not built — run `just build-cli`")


def write_inbox(path: Path, messages: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(messages), encoding="utf-8")


@_CLI_SKIP
class OCPluginDrainToSpoolTests(unittest.TestCase):
    def test_drain_inbox_to_spool_archives_and_clears_inbox(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            broker_root = root / "broker"
            session_id = "opencode-local"
            spool_path = root / "spool" / "opencode-plugin-spool.json"
            inbox_path = broker_root / f"{session_id}.inbox.json"
            write_inbox(
                inbox_path,
                [
                    {
                        "from_alias": "alice",
                        "to_alias": session_id,
                        "content": "hello from broker",
                    }
                ],
            )

            env = {
                **os.environ,
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": session_id,
            }
            result = subprocess.run(
                [
                    str(CLI_EXE),
                    "oc-plugin",
                    "drain-inbox-to-spool",
                    "--spool-path",
                    str(spool_path),
                    "--json",
                ],
                cwd=REPO,
                env=env,
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["count"], 1)
            self.assertEqual(payload["messages"][0]["content"], "hello from broker")

            spooled = json.loads(spool_path.read_text(encoding="utf-8"))
            self.assertEqual(len(spooled), 1)
            self.assertEqual(spooled[0]["content"], "hello from broker")
            self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

            archive_path = broker_root / "archive" / f"{session_id}.jsonl"
            self.assertTrue(archive_path.exists())
            archive_entries = [
                json.loads(line)
                for line in archive_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertEqual(len(archive_entries), 1)
            self.assertEqual(archive_entries[0]["content"], "hello from broker")

    def test_drain_inbox_to_spool_preserves_inbox_when_spool_write_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            broker_root = root / "broker"
            session_id = "opencode-local"
            inbox_path = broker_root / f"{session_id}.inbox.json"
            write_inbox(
                inbox_path,
                [
                    {
                        "from_alias": "alice",
                        "to_alias": session_id,
                        "content": "keep me",
                    }
                ],
            )

            unwritable_dir = root / "sealed"
            unwritable_dir.mkdir()
            unwritable_dir.chmod(stat.S_IREAD | stat.S_IEXEC)
            spool_path = unwritable_dir / "spool.json"

            env = {
                **os.environ,
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": session_id,
            }
            try:
                result = subprocess.run(
                    [
                        str(CLI_EXE),
                        "oc-plugin",
                        "drain-inbox-to-spool",
                        "--spool-path",
                        str(spool_path),
                        "--json",
                    ],
                    cwd=REPO,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=CLI_TIMEOUT,
                )
            finally:
                unwritable_dir.chmod(stat.S_IWUSR | stat.S_IREAD | stat.S_IEXEC)

            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("spool", result.stderr.lower())
            remaining = json.loads(inbox_path.read_text(encoding="utf-8"))
            self.assertEqual(len(remaining), 1)
            self.assertEqual(remaining[0]["content"], "keep me")
            self.assertFalse((broker_root / "archive" / f"{session_id}.jsonl").exists())


@_CLI_SKIP
class InstallOpencodeParityTests(unittest.TestCase):
    def test_install_opencode_writes_c2c_cli_command_into_shared_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            target_dir = Path(tmp) / "project"
            target_dir.mkdir()
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir()
            env = {
                **os.environ,
                "C2C_MCP_BROKER_ROOT": str(broker_root),
            }

            result = subprocess.run(
                [
                    str(CLI_EXE),
                    "install",
                    "opencode",
                    "--target-dir",
                    str(target_dir),
                    "--json",
                ],
                cwd=REPO,
                env=env,
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            config_path = Path(payload["config"])
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env_cfg = config["mcp"]["c2c"]["environment"]

            self.assertEqual(env_cfg["C2C_MCP_BROKER_ROOT"], str(broker_root))
            self.assertEqual(env_cfg["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
            self.assertEqual(env_cfg["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
            self.assertEqual(env_cfg["C2C_CLI_COMMAND"], str(CLI_EXE))
            self.assertNotIn("C2C_MCP_SESSION_ID", env_cfg)
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env_cfg)


@_CLI_SKIP
class StartOpencodeRefreshParityTests(unittest.TestCase):
    def test_start_opencode_refresh_writes_shared_c2c_cli_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(
                ["git", "init"],
                cwd=root,
                check=True,
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT,
            )
            broker_root = root / "broker"
            broker_root.mkdir()
            instances_dir = root / "instances"
            instances_dir.mkdir()
            opencode_dir = root / ".opencode"
            opencode_dir.mkdir()
            config_path = opencode_dir / "opencode.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mcp": {
                            "c2c": {
                                "environment": {
                                    "C2C_MCP_SESSION_ID": "stale-session",
                                    "C2C_MCP_AUTO_REGISTER_ALIAS": "stale-alias",
                                }
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )

            stub = root / "opencode"
            stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            stub.chmod(0o755)

            env = clean_c2c_start_env(os.environ)
            env.update(
                {
                    "PATH": str(root) + ":" + env.get("PATH", ""),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_INSTANCES_DIR": str(instances_dir),
                }
            )

            proc = spawn_tracked(
                [str(CLI_EXE), "start", "opencode", "-n", "managed-opencode"],
                cwd=str(root),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            stdout, stderr = proc.communicate(timeout=CLI_TIMEOUT)
            self.assertEqual(proc.returncode, 0, f"stdout={stdout!r} stderr={stderr!r}")

            config = json.loads(config_path.read_text(encoding="utf-8"))
            env_cfg = config["mcp"]["c2c"]["environment"]
            self.assertEqual(env_cfg["C2C_MCP_BROKER_ROOT"], str(broker_root))
            self.assertEqual(env_cfg["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
            self.assertEqual(env_cfg["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
            self.assertEqual(env_cfg["C2C_CLI_COMMAND"], str(CLI_EXE))
            self.assertNotIn("C2C_MCP_SESSION_ID", env_cfg)
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env_cfg)
