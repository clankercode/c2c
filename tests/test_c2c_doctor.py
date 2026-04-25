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
DOCS_DRIFT_SCRIPT = REPO / "scripts" / "c2c-docs-drift.py"


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

    def test_docs_drift_script_exists(self):
        self.assertTrue(DOCS_DRIFT_SCRIPT.exists())

    def test_docs_drift_script_is_executable(self):
        self.assertTrue(os.access(DOCS_DRIFT_SCRIPT, os.X_OK))


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


class DocsDriftTests(unittest.TestCase):
    """Test the static CLAUDE.md drift audit."""

    def _make_repo(self):
        d = Path(tempfile.mkdtemp())
        (d / "scripts").mkdir()
        (d / "ocaml" / "cli").mkdir(parents=True)
        (d / "ocaml" / "cli" / "c2c.ml").write_text(
            'let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send.") send_cmd\n'
            'let rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rooms" ~doc:"Rooms.") rooms_cmd\n'
            'let all_cmds = [ send; rooms ] in\n',
            encoding="utf-8",
        )
        (d / "scripts" / "relay-smoke-test.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        return d

    def test_docs_drift_reports_missing_path_and_command(self):
        d = self._make_repo()
        try:
            (d / "CLAUDE.md").write_text(
                "Run `./scripts/relay-smoke-test.sh` after deploy.\n"
                "Bad path: `.collab/runbooks/missing.md`.\n"
                "Good command: `c2c send peer hello`.\n"
                "Bad command: `c2c join room`.\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(DOCS_DRIFT_SCRIPT), "--repo", str(d), "--summary"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("2 drift finding(s)", result.stdout)
            self.assertIn(".collab/runbooks/missing.md", result.stdout)
            self.assertIn("c2c join", result.stdout)
            self.assertNotIn("relay-smoke-test.sh (repo path does not exist)", result.stdout)
            self.assertNotIn("c2c send (top-level", result.stdout)
        finally:
            import shutil
            shutil.rmtree(d)

    def test_docs_drift_warn_only_exits_zero(self):
        d = self._make_repo()
        try:
            (d / "CLAUDE.md").write_text("Bad command: `c2c missing`.\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(DOCS_DRIFT_SCRIPT), "--repo", str(d), "--summary", "--warn-only"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("1 drift finding(s)", result.stdout)
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

    def test_script_prints_docs_drift_audit(self):
        d, git, env = self._make_temp_repo()
        try:
            (Path(d) / "ocaml" / "cli").mkdir(parents=True)
            (Path(d) / "ocaml" / "cli" / "c2c.ml").write_text(
                'let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send.") send_cmd\n'
                'let all_cmds = [ send ] in\n',
                encoding="utf-8",
            )
            (Path(d) / "CLAUDE.md").write_text("Bad command: `c2c missing`.\n", encoding="utf-8")
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
            self.assertIn("=== docs drift audit ===", result.stdout)
            self.assertIn("1 drift finding(s)", result.stdout)
            self.assertIn("c2c missing", result.stdout)
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


@unittest.skipUnless(C2C_BIN.exists(), f"c2c binary not found at {C2C_BIN}")
class DoctorIntegrationTests(unittest.TestCase):
    """End-to-end integration tests for `c2c doctor`.

    Runs `c2c doctor` (which delegates to scripts/c2c-doctor.sh) against a
    temp broker root and verifies the audit sections are emitted.
    """

    def test_doctor_emits_command_test_audit_section(self):
        """`c2c doctor` must emit the command-test-audit section."""
        import shutil
        broker_root = tempfile.mkdtemp()
        try:
            result = subprocess.run(
                [str(C2C_BIN), "doctor"],
                capture_output=True, text=True,
                cwd=str(REPO),
                env={**os.environ, "C2C_MCP_BROKER_ROOT": broker_root},
            )
            self.assertIn("=== command test audit ===", result.stdout,
                          f"command-test-audit section missing. stdout:\n{result.stdout}")
        finally:
            shutil.rmtree(broker_root)

    def test_doctor_emits_duplication_scan_section(self):
        """`c2c doctor` must emit the duplication scan section (dup-scanner)."""
        import shutil
        broker_root = tempfile.mkdtemp()
        try:
            result = subprocess.run(
                [str(C2C_BIN), "doctor"],
                capture_output=True, text=True,
                cwd=str(REPO),
                env={**os.environ, "C2C_MCP_BROKER_ROOT": broker_root},
            )
            self.assertIn("=== duplication scan ===", result.stdout,
                          f"duplication scan section missing. stdout:\n{result.stdout}")
        finally:
            shutil.rmtree(broker_root)

    def test_command_test_audit_produces_gap_count(self):
        """command-test-audit script must run and report a gap count."""
        import shutil
        broker_root = tempfile.mkdtemp()
        try:
            result = subprocess.run(
                [str(C2C_BIN), "doctor"],
                capture_output=True, text=True,
                cwd=str(REPO),
                env={**os.environ, "C2C_MCP_BROKER_ROOT": broker_root},
            )
            self.assertRegex(result.stdout, r"=== command test audit ===",
                             "command-test-audit section missing")
            self.assertRegex(result.stdout, r"gap\(s\)",
                             f"command-test-audit produced no gap count. stdout:\n{result.stdout}")
        finally:
            shutil.rmtree(broker_root)

    def test_dup_scanner_produces_cluster_or_suppressed_output(self):
        """dup-scanner must run and produce cluster or suppressed output."""
        import shutil
        broker_root = tempfile.mkdtemp()
        try:
            result = subprocess.run(
                [str(C2C_BIN), "doctor"],
                capture_output=True, text=True,
                cwd=str(REPO),
                env={**os.environ, "C2C_MCP_BROKER_ROOT": broker_root},
            )
            self.assertRegex(result.stdout, r"=== duplication scan ===",
                             "duplication scan section missing")
            self.assertRegex(result.stdout, r"cluster|CLUSTER|suppressed",
                             f"dup-scanner produced no cluster/suppressed output. stdout:\n{result.stdout}")
        finally:
            shutil.rmtree(broker_root)
