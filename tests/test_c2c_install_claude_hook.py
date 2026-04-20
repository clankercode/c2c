"""Regression guard for the Claude Code hook body written by `c2c install claude`.

Two real bugs this guards against:

1. `exec c2c hook` inside the hook script triggers a Node.js/libuv waitpid
   race and ECHILD floods every PostToolUse. See
   .collab/findings/2026-04-19T09-08-00Z-opus-host-posttooluse-hook-echild-race.md
   and .collab/findings/2026-04-20T12-57-10Z-coder2-expert-echild-hook-regressions.md.
   The fix is to run `c2c hook` as a plain bash subprocess and `exit 0` from
   bash — never `exec`. This test asserts the word `exec ` is absent from the
   body the installer writes, catching any future regression where an agent
   copy-pastes an exec wrapper back in.

2. The installer previously had two divergent hook writers (canonical
   `claude_hook_script` and an inline body inside `setup_claude`) — the inline
   one regressed to `exec` and silently clobbered the canonical fix on every
   `c2c install claude`. This test exercises the actual install path, so any
   future divergence is caught end-to-end rather than only at the
   constant-definition site.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"


class InstallClaudeHookBodyTests(unittest.TestCase):
    def setUp(self):
        if not BINARY.exists():
            self.skipTest(
                f"c2c binary missing at {BINARY}; "
                "run `dune build ./ocaml/cli/c2c.exe` first"
            )
        self.temp_dir = tempfile.TemporaryDirectory()
        self.home = Path(self.temp_dir.name)
        (self.home / ".claude").mkdir()

    def tearDown(self):
        self.temp_dir.cleanup()

    def _run_install(self):
        env = {
            **os.environ,
            "HOME": str(self.home),
            # Keep install from touching the real broker / shared state.
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }
        return subprocess.run(
            [str(BINARY), "install", "claude", "--force"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_hook_body_has_no_exec_and_canonical_contents(self):
        result = self._run_install()
        self.assertEqual(
            result.returncode,
            0,
            f"install exited {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )

        hook_path = self.home / ".claude" / "hooks" / "c2c-inbox-check.sh"
        self.assertTrue(
            hook_path.exists(),
            f"installer did not create hook at {hook_path}",
        )
        body = hook_path.read_text(encoding="utf-8")

        self.assertIn(
            "c2c hook",
            body,
            "canonical `c2c hook` invocation missing from hook body",
        )
        self.assertIn(
            "exit 0",
            body,
            "explicit `exit 0` missing — bash must exit normally, not exec",
        )
        # Strip comment lines (# ...) and blank lines; the anti-exec doc comment
        # itself contains the word "exec", but it must not appear in executable code.
        code_lines = [
            line
            for line in body.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        offending = [line for line in code_lines if "exec " in line]
        self.assertFalse(
            offending,
            "REGRESSION: hook body contains `exec ` in executable code, which "
            "triggers ECHILD in Claude Code's Node.js hook runner. Use "
            "`c2c hook; exit 0` (run as bash subprocess) instead.\nOffending "
            "lines:\n" + "\n".join(offending) + "\nFull body:\n" + body,
        )

    def test_hook_is_executable(self):
        self._run_install()
        hook_path = self.home / ".claude" / "hooks" / "c2c-inbox-check.sh"
        mode = hook_path.stat().st_mode & 0o777
        self.assertTrue(
            mode & 0o100,
            f"hook at {hook_path} is not user-executable (mode {oct(mode)})",
        )


if __name__ == "__main__":
    unittest.main()
