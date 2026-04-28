"""#418: get-tmux-location must be pane-bound (race-free) and fast.

The fix: the OCaml `get-tmux-location` subcommand reads `$TMUX_PANE` and
passes it via `-t <pane>` to `tmux display-message`. We verify by
swapping in a fake `tmux` on PATH that records its argv and returns a
deterministic pane-bound answer based on the `-t` argument.

This test is fixture-driven (no real tmux server needed). The race fix
is validated by asserting the binary forwards the pane-id correctly:
two concurrent invocations with different `$TMUX_PANE` values get back
their own pane's id.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BIN = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"

CLI_TIMEOUT_SECONDS = 10


FAKE_TMUX_SCRIPT = r"""#!/bin/bash
# Fake tmux for #418 test. Returns the session:window.pane the caller asked
# for via -t <pane>. The map of pane-id -> location is encoded in env vars
# FAKE_TMUX_PANE_<id>.
#
#   tmux display-message -t %42 -p '#S:#I.#P'
#
# We scan argv for `-t <id>` and emit FAKE_TMUX_PANE_<id> if set, otherwise
# FAKE_TMUX_DEFAULT.

target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then
    target="$arg"
  fi
  prev="$arg"
done

# Sanitize pane id to env-var-safe (strip leading %, etc.)
key="FAKE_TMUX_PANE_${target//%/}"
val="${!key}"
if [ -n "$val" ]; then
  echo "$val"
else
  echo "${FAKE_TMUX_DEFAULT:-0:0.0}"
fi
"""


class GetTmuxLocationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BIN.exists():
            raise unittest.SkipTest(f"c2c.exe not built at {BIN}; run dune build first")

        # Build a fake-tmux dir on PATH
        cls.tmpdir = tempfile.mkdtemp(prefix="c2c_tmux_test_")
        fake = Path(cls.tmpdir) / "tmux"
        fake.write_text(FAKE_TMUX_SCRIPT)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        cls.fake_tmux_dir = cls.tmpdir

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmpdir, ignore_errors=True)

    def _env(self, pane_id, *, pane_map):
        env = os.environ.copy()
        env["PATH"] = f"{self.fake_tmux_dir}:{env['PATH']}"
        env["TMUX"] = "/tmp/fake-tmux-socket,1234,0"
        env["TMUX_PANE"] = pane_id
        for k, v in pane_map.items():
            env[f"FAKE_TMUX_PANE_{k.lstrip('%')}"] = v
        env["FAKE_TMUX_DEFAULT"] = "WRONG:0.0"  # if -t is missing, this leaks
        return env

    def _run(self, env):
        return subprocess.run(
            [str(BIN), "get-tmux-location"],
            env=env,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )

    def test_pane_bound_query(self):
        """get-tmux-location forwards $TMUX_PANE via -t to tmux."""
        pane_map = {"%42": "0:1.2", "%43": "0:3.4"}
        env = self._env("%42", pane_map=pane_map)
        result = self._run(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0:1.2")

    def test_concurrent_invocation_no_crosstalk(self):
        """Two concurrent invocations with different $TMUX_PANE values
        each return their own pane's location — the race fix.

        Pre-fix this could cross-talk because the underlying call was
        `tmux display-message -p` (server-active pane). Now it's
        `tmux display-message -t "$TMUX_PANE" -p` (caller-bound).
        """
        pane_map = {f"%{n}": f"0:{n}.0" for n in (10, 20, 30, 40, 50)}
        panes = list(pane_map.keys())

        def call(pane):
            env = self._env(pane, pane_map=pane_map)
            r = self._run(env)
            return pane, r

        with ThreadPoolExecutor(max_workers=len(panes)) as ex:
            futures = [ex.submit(call, p) for p in panes]
            results = {pane: r for fut in as_completed(futures) for pane, r in [fut.result()]}

        for pane in panes:
            r = results[pane]
            self.assertEqual(r.returncode, 0, f"{pane}: {r.stderr}")
            expected = pane_map[pane]
            self.assertEqual(
                r.stdout.strip(),
                expected,
                f"pane {pane} got {r.stdout.strip()!r}, expected {expected!r}",
            )

    def test_no_tmux_env_errors(self):
        """When neither TMUX nor TMUX_PANE is set, error out."""
        env = os.environ.copy()
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        env["PATH"] = f"{self.fake_tmux_dir}:{env['PATH']}"
        r = subprocess.run(
            [str(BIN), "get-tmux-location"],
            env=env,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
