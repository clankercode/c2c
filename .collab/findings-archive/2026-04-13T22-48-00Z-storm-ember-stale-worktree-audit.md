# Stale Worktree Audit

## Finding
Four git worktrees exist under `.worktrees/`, all on commits far behind `master` (3751b7e). Two have uncommitted changes that appear to be early prototypes superseded by master.

## Worktrees inspected

1. **c2c-envelope-metadata** (`fdb8f43`)
   - Clean working tree.
   - Commit message: "add all-sessions c2c list mode".
   - Functionality superseded by `c2c list --broker` and recent list/whoami work in master.

2. **c2c-registration** (`f39584c`)
   - Clean working tree.
   - Commit message: "add ocaml c2c mcp server".
   - The OCaml MCP server has evolved significantly in master; this branch is obsolete.

3. **opencode-local-onboarding** (`17e367e`)
   - Modified: `.collab/findings/2026-04-13T03-52-00Z-codex-problems-log.md`, `tests/test_c2c_cli.py` (+157 lines of early `run-opencode-inst` dry-run tests).
   - Untracked: `.collab/findings/2026-04-13T05-28-03Z-opencode-problems-log.md`, `.opencode/`, `docs/superpowers/plans/2026-04-13-opencode-local-onboarding.md`, `run-opencode-inst`, `run-opencode-inst-outer`, `run-opencode-inst.d/`.
   - The dry-run tests in the diff are for an early prototype of `run-opencode-inst`. Master already has comprehensive tests (`test_run_opencode_inst_dry_run_reports_local_config_and_session`, `test_run_opencode_inst_rearm_dry_run_reports_bg_loop_commands`, etc.) that match the evolved implementation.
   - The untracked `run-opencode-inst*` scripts are obsolete prototypes.
   - Verdict: safe to remove.

4. **two-session-pty-harness** (`1cb5a45`)
   - Modified: `c2c_mcp.py` (early `sync_broker_registry`, now in master), `ocaml/c2c_mcp.ml` (minor), `tests/test_c2c_cli.py` (+1569 lines).
   - Untracked: `claude_pty_harness.py` (early PTY harness prototype).
   - `sync_broker_registry` exists in master. The test additions cover early harness behavior that has been replaced by `c2c_poker.py`, `claude_send_msg.py`, and the managed outer-loop scripts.
   - Verdict: safe to remove.

## Action
Removed all four worktrees to reduce repository clutter and prevent future agents from accidentally working on obsolete code.

## Verification
After removal:
- `git worktree list` shows only the main worktree.
- `git status` remains clean.
- All 292 Python tests still pass.
