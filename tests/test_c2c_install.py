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


class C2CInstallDryRunTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.test_dir = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def invoke_cli(self, *args, env=None):
        merged_env = {**os.environ}
        if env:
            merged_env.update(env)
        merged_env.setdefault("C2C_MCP_SESSION_ID", "dry-run-test")
        return subprocess.run(
            [str(REPO / "c2c"), *args],
            cwd=REPO,
            env=merged_env,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )

    def test_install_dry_run_codex_produces_dry_run_lines(self):
        result = self.invoke_cli("install", "codex", "--dry-run", "--alias", "test-dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN]", result.stdout)
        self.assertIn("would create directory", result.stdout)
        self.assertIn("would write", result.stdout)

    def test_install_dry_run_kimi_produces_dry_run_lines(self):
        result = self.invoke_cli("install", "kimi", "--dry-run", "--alias", "test-dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN]", result.stdout)

    def test_install_dry_run_opencode_produces_dry_run_lines(self):
        result = self.invoke_cli(
            "install", "opencode", "--dry-run", "--alias", "test-dry-run", "--force"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN]", result.stdout)
        self.assertIn("would symlink", result.stdout)

    def test_install_dry_run_crushing_produces_dry_run_lines(self):
        result = self.invoke_cli("install", "crush", "--dry-run", "--alias", "test-dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[DRY-RUN]", result.stdout)

    def test_install_dry_run_claude_produces_dry_run_lines(self):
        merged_env = {**os.environ}
        merged_env.setdefault("C2C_MCP_SESSION_ID", "dry-run-test")
        proc = subprocess.Popen(
            [str(REPO / "c2c"), "install", "claude", "--dry-run", "--alias", "test-dry-run"],
            cwd=REPO,
            env=merged_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = proc.communicate(input="n\n", timeout=CLI_TIMEOUT_SECONDS)
        self.assertEqual(proc.returncode, 0, stderr)
        self.assertIn("[DRY-RUN]", stdout)

    def test_install_dry_run_leaves_filesystem_unchanged(self):
        def mtimes():
            paths = [
                Path.home() / ".codex" / "config.toml",
                Path.home() / ".kimi" / "mcp.json",
                Path.home() / ".claude" / ".claude.json",
                Path.home() / ".config" / "crush" / "crush.json",
            ]
            return {str(p): p.stat().st_mtime for p in paths if p.exists()}

        before = mtimes()
        for client in ["codex", "kimi", "crush"]:
            result = self.invoke_cli("install", client, "--dry-run", "--alias", "test-dry-run")
            self.assertEqual(result.returncode, 0, f"{client} failed: {result.stderr}")
        after = mtimes()
        self.assertEqual(before, after, "filesystem was modified by --dry-run")


if __name__ == "__main__":
    unittest.main()
