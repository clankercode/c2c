# I010 `c2c restart-stale` — implementation + live dogfood receipt

Date: 2026-07-12. Branch: `i010-restart-stale`. Author: claude (Max-driven).

## What shipped

- **`C2c_stale`** (`ocaml/cli/c2c_stale.{ml,mli}`) — version-aware staleness
  primitive. `classify ~installed_exe pid` compares a running pid's
  `/proc/<pid>/exe` against the installed binary (`/proc/self/exe`): same
  device+inode ⇒ `Current` (fast path); on inode mismatch (which `install-all`'s
  rm+cp mints on *every* install) confirm by size then SHA-256 so an identical
  reinstall is not falsely flagged. `compare_images ~target ~installed` is the
  testable core.
- **`c2c restart-stale`** (`ocaml/cli/c2c_managed_cmd.ml`, Tier2) — enumerate
  running managed instances (`read_managed_instances`), classify each, and
  rolling-restart the stale ones. Coordinator restarted **last** (kept alive);
  `--exclude-coordinator`, `--dry-run`, `--force`, `--json`, `--timeout`.
- **Post-install prompt** (`scripts/c2c-post-install-restart-prompt.sh`, wired
  into `just install-all`) — TTY-gated offer to run `restart-stale`;
  non-interactive / `C2C_SKIP_RESTART_PROMPT=1` prints the follow-up command and
  never blocks; silent when nothing is stale.

## Restart mechanism + the design gap it works around

`c2c restart <name>` **execve's into the new supervisor and hands it the
caller's controlling terminal** (`c2c_start.ml` `cmd_restart` / line ~478,
~5960). So a batch process that child-spawns `c2c restart` for a **TUI/hook**
client (claude/opencode/kimi/gemini/codex-hook) would drag that agent off its
own tmux pane onto restart-stale's terminal — and multiple restarts would fight
over one terminal. The design doc's increment-3 "child-spawn `c2c restart` for
each" is therefore unsafe *as literally stated* for TUI clients.

**Resolution (v1):**
- **App-server Codex** — safe to auto-drive. `c2c restart` diverts to the B153
  owner-control seam: the child only *writes a restart request* and awaits the
  result; the **live owner self-reexecs in its own pane** (`c2c_codex_session.ml`
  `restart_requested` → `execve`). The child exits 0/2/3, capturing nobody's
  terminal. restart-stale spawns it and maps the exit code.
- **TUI/hook clients** — reported as `guided` with the exact
  `c2c restart <name>` to run in-pane. Safe *automated* in-place TUI restart
  needs a generalized outer-loop restart seam (mirror B153 for `run_outer_loop`)
  and per-client live proof — that is exactly follow-up idea **I011**.

## Live dogfood (real processes, this machine, 2026-07-12)

Fixture instances backed by real long-lived `c2c monitor` processes; classified
with the freshly-built binary. No codex quota spent.

1. **Stale detection** — instance `outer.pid` → live `~/.local/bin/c2c`
   (0.11.0, no `restart-stale`, different content). Result:
   `stale-old -> stale / guided`, `manual: c2c restart stale-old`. ✓
2. **Current detection** — instance `outer.pid` → live new-build `c2c.exe`.
   Result: `current-new -> current / skipped (already current)`. ✓
3. **App-server auto-restart routing** — instance with `codex-session.json`
   mapping + live sleeper as owner. `restart-stale --force --timeout 2` →
   spawned `c2c restart codex-appsrv` → child took the owner seam, wrote
   `restart.request.json`, timed out with no live owner (exit 3) →
   `codex-appsrv -> stale / failed / timed out waiting for app-server owner`,
   `ok:false`. ✓ Proves the full routing + child spawn + owner-seam invocation +
   exit-code handling.

## Automated tests

- `ocaml/cli/test_c2c_stale.ml` — 8 cases: same-inode Current, identical-content
  cross-inode Current, differing-content Stale, differing-size Stale, missing
  target/installed Unknown, classify-self Current, dead-pid Unknown.
- `ocaml/test/test_c2c_restart_stale.ml` — 2 CLI integration cases against a
  fixture `C2C_INSTANCES_DIR`: stale TUI → guided (never auto-restarted in
  dry-run), dead instance excluded; empty dir → ok.

## Remaining live check (deploy-gate, not a code gap)

A **successful** app-server Codex restart-in-place (owner accepts → reexecs →
resumes the same thread, ledger continuity, no duplicate injection) needs a real
managed `c2c new codex` session. The owner-side reexec is B153 code already
proven live (see `p1-codex-appserver-run-complete`); restart-stale only feeds it
via `c2c restart`, and that hand-off is proven above (case 3). Run one real
managed-codex restart-stale before any deploy that relies on it.
