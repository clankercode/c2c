import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def just_dry_run(recipe: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["just", "--dry-run", recipe],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=5,
    )


def combined_output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


class JustfileTests(unittest.TestCase):
    def test_install_installs_ocaml_binaries_not_python_wrappers(self):
        result = just_dry_run("install")
        output = combined_output(result)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("./ocaml/cli/c2c.exe", output)
        self.assertIn("./ocaml/server/c2c_mcp_server.exe", output)
        self.assertIn("~/.local/bin/cc-quota", output)
        self.assertNotIn("c2c_install.py", output)

    def test_install_python_legacy_refuses_by_default(self):
        """B123: install-python-legacy must not silently install Python wrappers."""
        result = just_dry_run("install-python-legacy")
        output = combined_output(result)

        # just --dry-run prints the recipe body; recipe must refuse unless
        # C2C_ALLOW_PYTHON_LEGACY=1 is set.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("C2C_ALLOW_PYTHON_LEGACY", output)
        self.assertIn("retired", output.lower())
        # Must not be an unconditional python3 c2c_install.py line.
        # The only python3 line is behind the escape-hatch branch.
        self.assertIn("just install-all", output)

    def test_install_rs_is_ocaml_install_alias(self):
        result = just_dry_run("install-rs")
        output = combined_output(result)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("./ocaml/cli/c2c.exe", output)
        self.assertNotIn("c2c_install.py", output)


if __name__ == "__main__":
    unittest.main()
