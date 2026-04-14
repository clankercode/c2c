import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))


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


class C2CInstallTests(unittest.TestCase):
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
                "c2c-inject",
                "c2c-install",
                "c2c-instances",
                "c2c-kimi-wake",
                "c2c-kimi-wire-bridge",
                "c2c-list",
                "c2c-opencode-wake",
                "c2c-poker-sweep",
                "c2c-poll-inbox",
                "c2c-prune",
                "c2c-register",
                "c2c-restart",
                "c2c-restart-me",
                "c2c-room",
                "c2c-send",
                "c2c-send-all",
                "c2c-setup",
                "c2c-start",
                "c2c-stop",
                "c2c-verify",
                "c2c-wake-peer",
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
        self.assertTrue((install_dir / "c2c-kimi-wire-bridge").exists())
        self.assertTrue((install_dir / "restart-opencode-self").exists())
        self.assertTrue((install_dir / "run-kimi-inst").exists())
        self.assertTrue((install_dir / "run-crush-inst").exists())
        self.assertTrue((install_dir / "c2c-watch").exists())
        self.assertTrue((install_dir / "c2c-whoami").exists())

    def test_install_wrapper_exec_points_to_git_common_root(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)

        result = self.invoke_cli("c2c-install", env=env)
        self.assertEqual(result_code(result), 0)

        wrapper_content = (install_dir / "c2c").read_text(encoding="utf-8")
        exec_line = next(
            line for line in wrapper_content.splitlines() if line.startswith("exec ")
        )
        exec_path = exec_line.split('"')[1]

        git_common_dir = subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"], text=True
        ).strip()
        expected_root = str(Path(git_common_dir).resolve().parent)
        self.assertTrue(
            exec_path.startswith(expected_root),
            f"exec path {exec_path!r} does not start with main repo root {expected_root!r}",
        )

    def test_install_reports_path_guidance_when_bin_not_on_path(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)
        env["PATH"] = "/usr/bin"

        result = self.invoke_cli("c2c-install", env=env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("not currently on PATH", result.stdout)


if __name__ == "__main__":
    unittest.main()
