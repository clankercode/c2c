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
    def test_check_runs_read_only_hermes_gate_before_build(self):
        result = just_dry_run("check")
        output = combined_output(result)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(output.index('just check-hermes-distribution'),
                        output.index('scripts/dune-build-locked.sh build'))
        gate = just_dry_run('check-hermes-distribution')
        self.assertEqual(gate.returncode, 0, gate.stderr)
        self.assertIn('tools/ci/check-hermes-distribution.py', combined_output(gate))
        self.assertNotIn('codegen-hermes-plugin', combined_output(gate))
        ci = (REPO / '.github/workflows/ci.yml').read_text(encoding='utf-8')
        self.assertLess(ci.index('just check-hermes-distribution'),
                        ci.index('run: just build'))

    def test_test_py_exposes_deprecated_compatibility_modules(self):
        result = just_dry_run("test-py")
        output = combined_output(result)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PYTHONPATH="$PWD/deprecated"', output)

    def test_install_installs_ocaml_binaries_not_python_wrappers(self):
        result = just_dry_run("install")
        output = combined_output(result)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("./ocaml/cli/c2c.exe", output)
        self.assertIn("./ocaml/server/c2c_mcp_server.exe", output)
        self.assertIn("~/.local/bin/cc-quota", output)
        self.assertNotIn("c2c_install.py", output)


    def test_install_rs_is_ocaml_install_alias(self):
        result = just_dry_run("install-rs")
        output = combined_output(result)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("./ocaml/cli/c2c.exe", output)
        self.assertNotIn("c2c_install.py", output)


if __name__ == "__main__":
    unittest.main()
