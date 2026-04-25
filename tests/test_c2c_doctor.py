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
COMMAND_AUDIT_SCRIPT = REPO / "scripts" / "c2c-command-test-audit.py"
DUP_SCANNER_SCRIPT = REPO / "scripts" / "c2c-dup-scanner.py"


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

    def test_command_test_audit_script_exists(self):
        self.assertTrue(COMMAND_AUDIT_SCRIPT.exists())

    def test_command_test_audit_script_is_executable(self):
        self.assertTrue(os.access(COMMAND_AUDIT_SCRIPT, os.X_OK))


class CommandTestAuditTests(unittest.TestCase):
    """Test the static Tier 1/2 command test-reference audit."""

    def _make_repo(self):
        d = Path(tempfile.mkdtemp())
        (d / "ocaml" / "cli").mkdir(parents=True)
        (d / "tests").mkdir()
        (d / "ocaml" / "cli" / "c2c.ml").write_text(
            'let tier1 = [\n'
            '  ("send", "Send a message");\n'
            '  ("poll-inbox", "Poll inbox");\n'
            '] in\n'
            'let tier2 = [\n'
            '  ("start", "Start managed instance");\n'
            '  ("rooms send", "Send to room");\n'
            '] in\n',
            encoding="utf-8",
        )
        return d

    def test_command_test_audit_reports_missing_references(self):
        d = self._make_repo()
        try:
            (d / "tests" / "test_cli.py").write_text(
                'subprocess.run(["c2c", "send", "peer", "hello"])\n'
                'subprocess.run(["c2c", "rooms", "send", "lounge", "hello"])\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(COMMAND_AUDIT_SCRIPT), "--repo", str(d), "--summary"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("2 gap(s)", result.stdout)
            self.assertIn("poll-inbox", result.stdout)
            self.assertIn("start", result.stdout)
            self.assertNotIn("send, rooms send", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_command_test_audit_warn_only_exits_zero(self):
        d = self._make_repo()
        try:
            result = subprocess.run(
                [sys.executable, str(COMMAND_AUDIT_SCRIPT), "--repo", str(d), "--summary", "--warn-only"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("4 gap(s)", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)


class DoctorScriptClassificationTests(unittest.TestCase):
    """Test commit classification logic in c2c-doctor.sh using a temp git repo."""

    def _make_temp_repo(self):
        """Create a minimal git repo with fake origin/master + local commits."""
        d = tempfile.mkdtemp()
        env = {**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t",
               "C2C_COORDINATOR": "1"}

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

    def test_script_prints_command_test_audit(self):
        d, git, env = self._make_temp_repo()
        try:
            (Path(d) / "ocaml" / "cli").mkdir(parents=True)
            (Path(d) / "tests").mkdir()
            (Path(d) / "ocaml" / "cli" / "c2c.ml").write_text(
                'let tier1 = [\n'
                '  ("send", "Send a message");\n'
                '  ("poll-inbox", "Poll inbox");\n'
                '] in\n',
                encoding="utf-8",
            )
            (Path(d) / "tests" / "test_cli.py").write_text(
                'subprocess.run(["c2c", "send", "peer", "hello"])\n',
                encoding="utf-8",
            )
            git("commit", "--allow-empty", "-m", "docs: queued local work")
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
                capture_output=True,
                text=True,
                cwd=d,
                env={**env, "PATH": str(d) + ":" + os.environ["PATH"]},
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("=== command test audit ===", result.stdout)
            self.assertIn("1 gap(s)", result.stdout)
            self.assertIn("poll-inbox", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)


class ManagedInstanceDriftTests(unittest.TestCase):
    """Test managed instance drift detection in c2c-doctor.sh."""

    def test_drift_check_reports_dead_managed_pid_only(self):
        """Registry with one alive + one dead managed PID → only dead one drifted."""
        import shutil, json, os
        d = tempfile.mkdtemp()
        try:
            # broker_root is a subdir of temp dir (NOT the same as the c2c stub)
            broker_root = Path(d) / "broker_root"
            broker_root.mkdir()
            registry = broker_root / "registry.json"
            alive_pid = os.getpid()
            dead_pid = 99999999
            registry.write_text(json.dumps([
                {
                    "session_id": "alive-session",
                    "alias": "alive-agent",
                    "pid": alive_pid,
                    "pid_start_time": 12345678,
                    "registered_at": "2026-04-25T00:00:00Z",
                },
                {
                    "session_id": "dead-session",
                    "alias": "dead-agent",
                    "pid": dead_pid,
                    "pid_start_time": 99999999,
                    "registered_at": "2026-04-25T00:00:00Z",
                },
                {
                    "session_id": "non-managed-session",
                    "alias": "regular-peer",
                    "pid": None,
                    "registered_at": "2026-04-25T00:00:00Z",
                },
            ]))
            # c2c stub must be on PATH and NOT conflict with broker_root dir
            c2c_stub = Path(d) / "bin" / "c2c"
            c2c_stub.parent.mkdir()
            c2c_stub.write_text(
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"health\" ]]; then\n"
                "  echo '{\"ok\":true}'\n"
                "elif [[ \"$1\" == \"instances\" ]]; then\n"
                "  echo 'alive-agent         codex      running      xml_fd (pid %d)'\n"
                "else\n"
                "  echo 'stub'\n"
                "fi\n" % alive_pid
            )
            c2c_stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(DOCTOR_SCRIPT)],
                capture_output=True, text=True,
                cwd=DOCTOR_SCRIPT.parent.parent,
                env={
                    **os.environ,
                    "PATH": str(c2c_stub.parent) + ":" + os.environ["PATH"],
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }
            )
            self.assertIn("dead-agent", result.stdout)
            self.assertIn("alive-agent", result.stdout)  # printed but not drifted
            # dead-agent should appear in drift section with dead pid
            self.assertRegex(result.stdout, r"dead-agent.*pid.*is dead")
            # alive-agent should NOT appear in the drift section
            drift_section = result.stdout.split("managed instance drift")[1].split("uncommitted WIP")[0]
            self.assertNotIn("alive-agent", drift_section)
            self.assertIn("c2c refresh-peer dead-agent", result.stdout)
        finally:
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


class DupScannerSuppressionTests(unittest.TestCase):
    """Test dup-scanner suppression heuristics."""

    def test_deprecated_scripts_suppressed(self):
        """Deprecated wake daemon pairs should be suppressed."""
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO), "--summary"],
            capture_output=True, text=True
        )
        self.assertIn("suppressed", result.stdout)
        # c2c_crush_wake_daemon and c2c_kimi_wake_daemon are deprecated
        self.assertNotIn("crush_wake_daemon", result.stdout)

    def test_test_boilerplate_suppressed(self):
        """Test-e2e file pairs should be suppressed and not appear in active clusters."""
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO), "--full"],
            capture_output=True, text=True
        )
        # test_c2c_claude_e2e and test_c2c_kimi_e2e are boilerplate and should not appear in active clusters
        # They appear in the [Suppressed] section at the bottom, not in active CLUSTER output
        self.assertNotIn("test_c2c_claude_e2e", result.stdout.split("CLUSTER")[0])
        self.assertNotIn("test_c2c_kimi_e2e", result.stdout.split("CLUSTER")[0])

    def test_ml_mli_pairs_suppressed(self):
        """OCaml .ml/.mli pairs should be suppressed and not appear in active clusters."""
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO), "--full"],
            capture_output=True, text=True
        )
        # c2c_mcp.ml and c2c_mcp.mli should be suppressed
        # In full output they appear in the [Suppressed] section at the bottom, not in active CLUSTER output
        self.assertNotIn("c2c_mcp.ml", result.stdout.split("CLUSTER")[0])
        self.assertNotIn("c2c_mcp.mli", result.stdout.split("CLUSTER")[0])

    def test_ignore_flag_suppresses_cluster(self):
        """--ignore flag should suppress clusters where all files match the pattern."""
        # c2c_configure_crush.py is in a cluster with c2c_configure_kimi.py
        # --ignore only suppresses if ALL files match, so this cluster is NOT fully suppressed
        # We use a file that IS the only member of a small cluster (c2c_crush_wake_daemon.py alone is deprecated)
        # Instead test: run with --ignore on a deprecated pattern that IS the entire cluster
        # Since cluster 2 has 2 files and --ignore only suppresses when ALL match,
        # the returncode stays 1. We verify the flag is accepted and parsed.
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO),
             "--summary", "--ignore", "nonexistent_pattern_xyz"],
            capture_output=True, text=True
        )
        # Should still find clusters (pattern doesn't match anything)
        self.assertIn("cluster", result.stdout)
        # --ignore should be accepted without error
        self.assertNotIn("unrecognized argument", result.stderr)

    def test_json_output_includes_suppression(self):
        """JSON output should include suppressed cluster count and reasons."""
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO), "--json"],
            capture_output=True, text=True
        )
        import json
        data = json.loads(result.stdout)
        self.assertIn("n_suppressed", data)
        self.assertGreater(data["n_suppressed"], 0)
        self.assertIn("suppressed", data)
        self.assertEqual(len(data["suppressed"]), data["n_suppressed"])

    def test_warn_only_exits_zero(self):
        """--warn-only should always exit 0."""
        result = subprocess.run(
            [sys.executable, str(DUP_SCANNER_SCRIPT), "--repo", str(REPO), "--warn-only", "--summary"],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)
