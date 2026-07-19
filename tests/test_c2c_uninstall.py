import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

CLI_TIMEOUT_SECONDS = 10


def run_cli(*args, env=None, cwd=REPO):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(REPO / "c2c"), *args],
        cwd=cwd,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def parse_json_stdout(text):
    """Return the last JSON object printed to stdout (handles preceding logs)."""
    lines = text.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith("{"):
            return json.loads("\n".join(lines[i:]))
    raise ValueError("no JSON object found in stdout")


class C2CUninstallTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp(prefix="c2c-uninstall-test-"))
        self.home = self.temp_dir / "home"
        self.home.mkdir()
        self.xdg_state = self.temp_dir / "state"
        self.xdg_state.mkdir()
        self.schedule_root = self.temp_dir / "schedules"
        self.schedule_root.mkdir()
        self.registry_path = self.temp_dir / "registry.yaml"
        self.words_path = self.temp_dir / "words.txt"
        self.words_path.write_text(
            "storm\nherald\nember\ncrown\nsilver\nbanner\n", encoding="utf-8"
        )
        self.alias = f"test-u2-{self.temp_dir.name[-8:]}"
        self.env = {
            "HOME": str(self.home),
            "XDG_STATE_HOME": str(self.xdg_state),
            "C2C_SCHEDULE_ROOT_OVERRIDE": str(self.schedule_root),
            "C2C_REGISTRY_PATH": str(self.registry_path),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def manifest(self):
        path = self.xdg_state / "c2c" / "install-manifest.json"
        if not path.exists():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def test_install_codex_writes_manifest_and_summary(self):
        result = run_cli("install", "codex", "--alias", self.alias, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed c2c for codex", result.stdout)
        self.assertIn("owned:", result.stdout)
        self.assertIn("shared (c2c stanza added to your files):", result.stdout)
        self.assertIn("To remove: c2c uninstall codex", result.stdout)

        m = self.manifest()
        self.assertIsNotNone(m)
        self.assertEqual(m["version"], 1)
        record = next(r for r in m["installs"] if r["component"] == "codex")
        self.assertEqual(record["alias"], self.alias)
        kinds = {a["kind"] for a in record["artifacts"]}
        self.assertIn("shared-toml-section", kinds)
        self.assertIn("owned-file", kinds)
        self.assertIn("schedule", kinds)

    def test_install_codex_json_summary(self):
        result = run_cli(
            "install", "codex", "--alias", self.alias, "--json", env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = parse_json_stdout(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["component"], "codex")
        self.assertIn("installed", payload)
        self.assertTrue(any(a["kind"] == "shared-toml-section" for a in payload["installed"]))

    def test_uninstall_codex_preserves_user_toml_and_is_idempotent(self):
        config = self.home / ".codex" / "config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("[user]\nkey = \"keep-me\"\n", encoding="utf-8")

        install = run_cli("install", "codex", "--alias", self.alias, env=self.env)
        self.assertEqual(install.returncode, 0, install.stderr)
        record = next(r for r in self.manifest()["installs"] if r["component"] == "codex")
        schedule_path = Path(next(a["path"] for a in record["artifacts"] if a["kind"] == "schedule"))
        self.assertTrue(schedule_path.exists())

        first = run_cli("uninstall", "codex", env=self.env)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("Removed c2c for codex", first.stdout)

        content = config.read_text(encoding="utf-8")
        self.assertIn('[user]', content)
        self.assertIn('key = "keep-me"', content)
        self.assertNotIn("[mcp_servers.c2c", content)
        self.assertFalse(schedule_path.exists())

        second = run_cli("uninstall", "codex", env=self.env)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("nothing to remove for codex", second.stdout)

    def test_uninstall_codex_recomputes_when_manifest_record_is_incomplete(self):
        config = self.home / ".codex" / "config.toml"
        config.parent.mkdir(parents=True)
        config.write_text(
            '[user]\nkey = "keep-me"\n\n'
            '[mcp_servers.c2c]\ncommand = "c2c"\n\n'
            '[mcp_servers.other]\ncommand = "echo"\n',
            encoding="utf-8",
        )
        manifest_path = self.xdg_state / "c2c" / "install-manifest.json"
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "installs": [
                        {
                            "component": "codex",
                            "alias": self.alias,
                            "target_dir": str(self.home),
                            "c2c_version": "test",
                            "ts": 0,
                            "artifacts": [],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        result = run_cli("uninstall", "codex", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        content = config.read_text(encoding="utf-8")
        self.assertIn("[mcp_servers.other]", content)
        self.assertNotIn("[mcp_servers.c2c", content)
        self.assertEqual(self.manifest()["installs"], [])

    def test_uninstall_kimi_preserves_user_json_keys(self):
        config = self.home / ".kimi" / "mcp.json"
        config.parent.mkdir(parents=True)
        config.write_text(
            json.dumps(
                {"mcpServers": {"other": {"command": "echo"}}, "keep": True},
                indent=2,
            ),
            encoding="utf-8",
        )

        install = run_cli("install", "kimi", "--alias", self.alias, env=self.env)
        self.assertEqual(install.returncode, 0, install.stderr)

        after_install = json.loads(config.read_text(encoding="utf-8"))
        self.assertIn("c2c", after_install["mcpServers"])

        first = run_cli("uninstall", "kimi", env=self.env)
        self.assertEqual(first.returncode, 0, first.stderr)

        after_uninstall = json.loads(config.read_text(encoding="utf-8"))
        self.assertIn("other", after_uninstall["mcpServers"])
        self.assertEqual(after_uninstall["mcpServers"]["other"]["command"], "echo")
        self.assertTrue(after_uninstall["keep"])
        self.assertNotIn("c2c", after_uninstall["mcpServers"])

        second = run_cli("uninstall", "kimi", env=self.env)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("nothing to remove for kimi", second.stdout)

    def test_uninstall_kimi_removes_legacy_toml_block_and_preserves_user_toml(self):
        config = self.home / ".kimi" / "config.toml"
        config.parent.mkdir(parents=True)
        config.write_text(
            'model = "keep-before"\n'
            '# c2c-managed PreToolUse hook (#142). Slice 2 - install side.\n'
            '# legacy block content\n'
            '# [[hooks]]\n'
            '# command = "/tmp/c2c-kimi-approval-hook.sh"\n'
            '\n'
            'after = "keep-after"\n',
            encoding="utf-8",
        )

        result = run_cli("uninstall", "kimi", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        content = config.read_text(encoding="utf-8")
        self.assertIn('model = "keep-before"', content)
        self.assertIn('after = "keep-after"', content)
        self.assertNotIn("c2c-managed PreToolUse hook", content)
        self.assertNotIn("legacy block content", content)

    def test_uninstall_opencode_preserves_user_json_keys(self):
        target = self.temp_dir / "project"
        target.mkdir()
        config = target / ".opencode" / "opencode.json"
        config.parent.mkdir(parents=True)
        config.write_text(
            json.dumps(
                {
                    "mcp": {
                        "other": {"command": "echo"},
                        "c2c": {"type": "local", "command": ["opam"]},
                    },
                    "keep": True,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        first = run_cli(
            "uninstall", "opencode", "--target-dir", str(target), env=self.env
        )
        self.assertEqual(first.returncode, 0, first.stderr)

        after = json.loads(config.read_text(encoding="utf-8"))
        self.assertIn("other", after.get("mcp", {}))
        self.assertTrue(after["keep"])
        self.assertNotIn("c2c", after.get("mcp", {}))

    def test_uninstall_self_dry_run_warns(self):
        result = run_cli("uninstall", "self", "--dry-run", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Would remove the running c2c binary", result.stdout)

    def test_install_self_dry_run_changes_nothing(self):
        dest = self.temp_dir / "bin"
        result = run_cli(
            "install", "self", "--dry-run", "--dest", str(dest), env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Would install c2c for self", result.stdout)
        self.assertFalse((dest / "c2c").exists())
        self.assertIsNone(self.manifest())

    def test_uninstall_git_shim_uses_recompute_fallback(self):
        shim_dir = self.temp_dir / "shim-bin"
        shim_dir.mkdir()
        for name in ("git", "git-pre-reset"):
            path = shim_dir / name
            path.write_text("#!/bin/sh\n", encoding="utf-8")
            path.chmod(0o755)
        env = {**self.env, "C2C_GIT_SHIM_DIR": str(shim_dir)}

        result = run_cli("uninstall", "git-shim", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((shim_dir / "git").exists())
        self.assertFalse((shim_dir / "git-pre-reset").exists())

    def test_uninstall_all_json_is_machine_readable(self):
        project = self.temp_dir / "all-project"
        project.mkdir()
        bin_dir = self.home / ".local" / "bin"
        bin_dir.mkdir(parents=True)
        c2c_bin = bin_dir / "c2c"
        c2c_bin.write_text("#!/bin/sh\n", encoding="utf-8")
        c2c_bin.chmod(0o755)

        result = run_cli("uninstall", "all", "--json", env=self.env, cwd=project)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["component"], "all")
        self.assertFalse(c2c_bin.exists())

    def test_uninstall_json_output(self):
        config = self.home / ".codex" / "config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("[user]\nkey = \"keep-me\"\n", encoding="utf-8")
        run_cli("install", "codex", "--alias", self.alias, env=self.env)

        result = run_cli("uninstall", "codex", "--json", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = parse_json_stdout(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertFalse(payload["dry_run"])
        self.assertEqual(payload["component"], "codex")
        self.assertTrue(len(payload["removed"]) > 0)

    def test_uninstall_unknown_component_errors(self):
        result = run_cli("uninstall", "not-a-component", env=self.env)
        self.assertEqual(result.returncode, 124)
        self.assertIn("unknown component", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
