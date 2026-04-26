import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CLI_EXE = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"
CLI_SKIP = unittest.skipUnless(CLI_EXE.exists(), "OCaml CLI binary not built - run `just build-cli`")
CLI_TIMEOUT = 10


def run_cli(args, *, cwd, env):
    return subprocess.run(
        [str(CLI_EXE), *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT,
    )


@CLI_SKIP
class PeerPassSendCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.repo = self.tmp_path / "repo"
        self.broker_root = self.tmp_path / "broker"
        self.repo.mkdir()
        self.broker_root.mkdir()

        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "slice author"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "author@example.invalid"], cwd=self.repo, check=True)
        (self.repo / "slice.txt").write_text("review me\n", encoding="utf-8")
        subprocess.run(["git", "add", "slice.txt"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "test slice"], cwd=self.repo, check=True)
        self.sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=self.repo, text=True).strip()

        self.env = os.environ.copy()
        self.env.update(
            {
                "C2C_MCP_BROKER_ROOT": str(self.broker_root),
                "C2C_MCP_AUTO_JOIN_ROOMS": "",
                "C2C_MCP_SESSION_ID": "reviewer-session",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "reviewer",
            }
        )

        reviewer = run_cli(["register", "--alias", "reviewer"], cwd=self.repo, env=self.env)
        self.assertEqual(reviewer.returncode, 0, reviewer.stderr)

        coord_env = dict(self.env)
        coord_env["C2C_MCP_SESSION_ID"] = "coord-session"
        coord_env["C2C_MCP_AUTO_REGISTER_ALIAS"] = "coordinator1"
        coordinator = run_cli(["register", "--alias", "coordinator1"], cwd=self.repo, env=coord_env)
        self.assertEqual(coordinator.returncode, 0, coordinator.stderr)

    def tearDown(self):
        self.tmp.cleanup()

    def test_peer_pass_send_signs_artifact_and_dms_target(self):
        result = run_cli(
            [
                "peer-pass",
                "send",
                "coordinator1",
                self.sha,
                "--verdict",
                "PASS",
                "--criteria",
                "build,docs",
                "--commit-range",
                f"{self.sha}~1..{self.sha}",
                "--branch",
                "slice/test",
                "--worktree",
                ".worktrees/test",
                "--notes",
                "ready",
                "--json",
            ],
            cwd=self.repo,
            env=self.env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["sent_to"], "coordinator1")
        self.assertEqual(payload["reviewer"], "reviewer")
        self.assertEqual(payload["sha"], self.sha)
        artifact_path = Path(payload["artifact_path"])
        if not artifact_path.is_absolute():
            artifact_path = self.repo / artifact_path
        self.assertTrue(artifact_path.exists())
        verify = run_cli(["peer-pass", "verify", str(artifact_path)], cwd=self.repo, env=self.env)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertIn("VERIFIED", verify.stdout)

        inbox = json.loads((self.broker_root / "coord-session.inbox.json").read_text(encoding="utf-8"))
        self.assertEqual(len(inbox), 1)
        self.assertEqual(inbox[0]["from_alias"], "reviewer")
        self.assertEqual(inbox[0]["to_alias"], "coordinator1")
        self.assertIn("peer-PASS by reviewer", inbox[0]["content"])
        self.assertIn(f"SHA={self.sha}", inbox[0]["content"])
        self.assertIn("branch=slice/test", inbox[0]["content"])
        self.assertIn("in .worktrees/test", inbox[0]["content"])
