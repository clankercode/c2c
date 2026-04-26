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


def run_c2c(args, *, memory_root, alias):
    env = os.environ.copy()
    env.update(
        {
            "C2C_MEMORY_ROOT_OVERRIDE": str(memory_root),
            "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }
    )
    return subprocess.run(
        [str(CLI_EXE), *args],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT,
    )


@CLI_SKIP
class C2CMemoryE2ETests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.memory_root = Path(self.tmp.name) / "memory"
        self.memory_root.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_cross_agent_private_and_shared_memory_cli_flow(self):
        private_write = run_c2c(
            ["memory", "write", "private-note", "--type", "note", "private body"],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(private_write.returncode, 0, private_write.stderr)

        shared_write = run_c2c(
            ["memory", "write", "shared-note", "--type", "reference", "--shared", "shared body"],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(shared_write.returncode, 0, shared_write.stderr)

        private_read = run_c2c(
            ["memory", "read", "private-note", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertNotEqual(private_read.returncode, 0)
        self.assertIn("private", private_read.stderr)
        self.assertIn("c2c memory share private-note", private_read.stderr)

        shared_read = run_c2c(
            ["memory", "read", "shared-note", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertEqual(shared_read.returncode, 0, shared_read.stderr)
        shared_payload = json.loads(shared_read.stdout)
        self.assertEqual(shared_payload["alias"], "alice")
        self.assertEqual(shared_payload["name"], "shared-note")
        self.assertEqual(shared_payload["type"], "reference")
        self.assertTrue(shared_payload["shared"])
        self.assertEqual(shared_payload["content"], "shared body\n")

        global_shared = run_c2c(
            ["memory", "list", "--shared", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertEqual(global_shared.returncode, 0, global_shared.stderr)
        items = json.loads(global_shared.stdout)
        self.assertEqual(
            items,
            [
                {
                    "alias": "alice",
                    "file": "shared-note.md",
                    "name": "shared-note",
                    "description": None,
                    "type": "reference",
                    "shared": True,
                    "shared_with": [],
                }
            ],
        )

    def test_targeted_memory_revoke_cli_flow(self):
        targeted_write = run_c2c(
            [
                "memory",
                "write",
                "handoff",
                "--type",
                "reference",
                "--shared-with",
                "bob,carol",
                "handoff body",
            ],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(targeted_write.returncode, 0, targeted_write.stderr)

        bob_read = run_c2c(
            ["memory", "read", "handoff", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertEqual(bob_read.returncode, 0, bob_read.stderr)
        self.assertEqual(json.loads(bob_read.stdout)["content"], "handoff body\n")

        revoke_bob = run_c2c(
            ["memory", "revoke", "handoff", "--alias", "bob", "--json"],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(revoke_bob.returncode, 0, revoke_bob.stderr)
        self.assertEqual(json.loads(revoke_bob.stdout)["shared_with"], ["carol"])

        bob_refused = run_c2c(
            ["memory", "read", "handoff", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertNotEqual(bob_refused.returncode, 0)
        self.assertIn("private", bob_refused.stderr)
        self.assertNotIn("handoff body", bob_refused.stdout)
        self.assertNotIn("handoff body", bob_refused.stderr)

        carol_read = run_c2c(
            ["memory", "read", "handoff", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="carol",
        )
        self.assertEqual(carol_read.returncode, 0, carol_read.stderr)
        self.assertEqual(json.loads(carol_read.stdout)["content"], "handoff body\n")

        bob_shared_with_me = run_c2c(
            ["memory", "list", "--shared-with-me", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertEqual(bob_shared_with_me.returncode, 0, bob_shared_with_me.stderr)
        self.assertEqual(json.loads(bob_shared_with_me.stdout), [])

        grant_bob = run_c2c(
            ["memory", "grant", "handoff", "--alias", "bob", "--json"],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(grant_bob.returncode, 0, grant_bob.stderr)
        self.assertEqual(json.loads(grant_bob.stdout)["shared_with"], ["carol", "bob"])

        bob_read_again = run_c2c(
            ["memory", "read", "handoff", "--alias", "alice", "--json"],
            memory_root=self.memory_root,
            alias="bob",
        )
        self.assertEqual(bob_read_again.returncode, 0, bob_read_again.stderr)

        clear_targeted = run_c2c(
            ["memory", "revoke", "handoff", "--all-targeted", "--json"],
            memory_root=self.memory_root,
            alias="alice",
        )
        self.assertEqual(clear_targeted.returncode, 0, clear_targeted.stderr)
        self.assertEqual(json.loads(clear_targeted.stdout)["shared_with"], [])

        carol_refused = run_c2c(
            ["memory", "read", "handoff", "--alias", "alice"],
            memory_root=self.memory_root,
            alias="carol",
        )
        self.assertNotEqual(carol_refused.returncode, 0)
