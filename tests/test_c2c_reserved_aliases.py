"""Tests for reserved alias enforcement in Broker.register and enqueue_message.

Reserved aliases (c2c, c2c-system) must be rejected at all entry points:
- CLI `c2c register --alias <name>`
- Direct Broker.register call (guards the CLI path)
- `c2c send` with from_alias spoofing (enqueue_message path)

admin is allowed locally (relay-boundary enforcement is a future concern).
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"


class ReservedAliasTests(unittest.TestCase):
    def setUp(self):
        if not BINARY.exists():
            self.skipTest(
                f"c2c binary missing at {BINARY}; "
                "run `dune build ./ocaml/cli/c2c.exe` first"
            )
        self.tmpdir = tempfile.TemporaryDirectory()
        self.broker_root = self.tmpdir.name

    def tearDown(self):
        self.tmpdir.cleanup()

    def _run(self, *args, extra_env=None):
        env = {
            **os.environ,
            "C2C_MCP_BROKER_ROOT": self.broker_root,
            "C2C_MCP_SESSION_ID": "test-session",
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(BINARY), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_register_rejects_c2c_alias(self):
        result = self._run("register", "--alias", "c2c", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved", result.stderr)

    def test_register_rejects_c2c_system_alias(self):
        result = self._run("register", "--alias", "c2c-system", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved", result.stderr)

    def test_register_allows_admin_locally(self):
        result = self._run("register", "--alias", "admin", "--json")
        self.assertEqual(result.returncode, 0,
                         f"admin should be allowed locally\nstderr: {result.stderr}")

    def test_register_allows_normal_alias(self):
        result = self._run("register", "--alias", "coder2-expert", "--json")
        self.assertEqual(result.returncode, 0,
                         f"Normal alias should succeed\nstderr: {result.stderr}")
