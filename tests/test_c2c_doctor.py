"""Tests for c2c doctor command and scripts/c2c-doctor.sh."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
C2C_BIN = Path(os.environ.get("C2C_BIN", str(Path.home() / ".local" / "bin" / "c2c")))
DOCTOR_SCRIPT = REPO / "scripts" / "c2c-doctor.sh"


class DoctorScriptExistenceTests(unittest.TestCase):
    """Verify the doctor script is present and well-formed."""

    def test_doctor_script_exists(self):
        self.assertTrue(DOCTOR_SCRIPT.exists(), f"scripts/c2c-doctor.sh not found at {DOCTOR_SCRIPT}")

    def test_doctor_script_is_executable(self):
        self.assertTrue(os.access(DOCTOR_SCRIPT, os.X_OK),
                        "scripts/c2c-doctor.sh is not executable")

    def test_doctor_script_shebang(self):
        first_line = DOCTOR_SCRIPT.read_text().splitlines()[0]
        self.assertTrue(first_line.startswith("#!/"),
                        f"Missing shebang in c2c-doctor.sh: {first_line!r}")

    def test_doctor_script_bash_syntax(self):
        """bash -n validates syntax without executing."""
        result = subprocess.run(
            ["bash", "-n", str(DOCTOR_SCRIPT)],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0,
                         f"bash -n failed: {result.stderr}")


class DoctorScriptClassificationTests(unittest.TestCase):
    """Test commit classification logic in c2c-doctor.sh using a temp git repo."""

    def _make_temp_repo(self):
        """Create a minimal git repo with fake origin/master + local commits."""
        d = tempfile.mkdtemp()
        env = {**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t"}

        def git(*args):
            return subprocess.run(["git", "-C", d] + list(args),
                                  check=True, capture_output=True, env=env)

        git("init")
        git("commit", "--allow-empty", "-m", "initial")
        git("branch", "-M", "master")
        # Fake remote tracking ref
        (Path(d) / ".git" / "refs" / "remotes" / "origin").mkdir(parents=True, exist_ok=True)
        origin_sha = subprocess.check_output(
            ["git", "-C", d, "rev-parse", "HEAD"]).decode().strip()
        (Path(d) / ".git" / "refs" / "remotes" / "origin" / "master").write_text(origin_sha + "\n")
        git("config", "branch.master.remote", "origin")
        git("config", "branch.master.merge", "refs/heads/master")
        return d, git, env

    def test_script_exits_zero_when_no_commits_ahead(self):
        """When up-to-date, doctor exits 0 immediately after health."""
        d, git, env = self._make_temp_repo()
        try:
            # Script calls `c2c health` which needs a broker — stub it
            stub = Path(d) / "c2c"
            stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo 'No managed instances.'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True, text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]}
            )
            self.assertEqual(result.returncode, 0,
                             f"stderr: {result.stderr}\nstdout: {result.stdout}")
            self.assertIn("up-to-date", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_script_treats_plain_fix_relay_message_as_local_only(self):
        """Message-only 'fix(relay)' is local-only without relay-server scope or files."""
        d, git, env = self._make_temp_repo()
        try:
            git("commit", "--allow-empty", "-m", "fix(relay): auth bypass")
            git("commit", "--allow-empty", "-m", "chore: update README")
            stub = Path(d) / "c2c"
            stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo 'No managed instances.'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True, text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]}
            )
            self.assertIn("fix(relay): auth bypass", result.stdout)
            self.assertIn("Local-only", result.stdout)
            self.assertNotIn("Relay/deploy critical", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_script_classifies_local_only_by_message(self):
        """Commits without relay-critical markers are local-only."""
        d, git, env = self._make_temp_repo()
        try:
            git("commit", "--allow-empty", "-m", "chore: update README")
            stub = Path(d) / "c2c"
            stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo 'No managed instances.'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True, text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]}
            )
            self.assertIn("Local-only", result.stdout)
            self.assertNotIn("PUSH RECOMMENDED", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_docs_relay_mention_is_not_relay_critical(self):
        """Commits touching only docs/ are local-only even if message mentions relay."""
        d, git, env = self._make_temp_repo()
        try:
            # Create a docs-only commit that mentions relay in the message
            docs_dir = Path(d) / "docs"
            docs_dir.mkdir()
            (docs_dir / "overview.md").write_text("relay.c2c.im live\n")
            git("add", "docs/overview.md")
            git("commit", "-m", "docs(website): mark relay.c2c.im live — v0.6.11 prod mode")
            stub = Path(d) / "c2c"
            stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo 'No managed instances.'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True, text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]}
            )
            self.assertIn("Local-only", result.stdout)
            self.assertNotIn("Relay/deploy critical", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_script_prints_managed_instances_section(self):
        d, git, env = self._make_temp_repo()
        try:
            stub = Path(d) / "c2c"
            stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo '  opencode-test        opencode   stopped      plugin'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True,
                text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]},
            )
            self.assertIn("=== managed instances ===", result.stdout)
            self.assertIn("opencode-test", result.stdout)
            self.assertIn("plugin", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)


@unittest.skipUnless(C2C_BIN.exists(), f"c2c binary not found at {C2C_BIN}")
class DoctorCLITests(unittest.TestCase):
    """Test that the c2c CLI has a doctor subcommand."""

    def test_doctor_help_text(self):
        result = subprocess.run(
            [str(C2C_BIN), "doctor", "--help"],
            capture_output=True, text=True
        )
        # --help may exit 0 or 1 depending on Cmdliner, but must not crash
        self.assertIn("doctor", result.stdout + result.stderr,
                      "doctor subcommand not found in help output")

    def test_doctor_in_main_help(self):
        result = subprocess.run(
            [str(C2C_BIN), "--help"],
            capture_output=True, text=True
        )
        self.assertIn("doctor", result.stdout + result.stderr)
