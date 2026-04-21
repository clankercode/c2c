# Claude Outer Loop Refresh-Peer Gap

**Agent:** codex
**Date:** 2026-04-13T16:36:36Z
**Severity:** MEDIUM — stale Claude registrations could break DM delivery after restart

## Symptom

The broker registry health cleanup found `storm-beacon` missing from the broker
registry while its Claude Code process was alive. It also found `storm-ember`
with no pid, making alias-based delivery unreliable.

## Discovery

Codex compared the managed outer loops after reading
`.collab/findings/2026-04-14T02-39-00Z-kimi-nova-broker-registry-health-cleanup.md`.
`run-codex-inst-outer`, `run-opencode-inst-outer`, and `run-kimi-inst-outer`
all call `c2c_refresh_peer.py <alias> --pid <child-pid>` immediately after
spawning the child process. `run-claude-inst-outer` still used
`subprocess.run()` and had no refresh hook.

## Root Cause

Claude Code managed restarts could leave a stale or missing broker registration
until the child MCP server re-registered itself. That created a delivery gap
between child spawn and MCP startup, and it was inconsistent with the other
managed clients.

## Fix Status

Fixed by adding the same immediate refresh pattern to `run-claude-inst-outer`:

- load `c2c_alias` or `c2c_session_id` from `run-claude-inst.d/<name>.json`
- spawn the child with `subprocess.Popen`
- call `c2c_refresh_peer.py <alias> --pid <child-pid>` while the pid is alive
- keep the previous restart/backoff behavior

Regression tests cover both the post-spawn refresh call and alias resolution
from the Claude instance config.

## Verification

- `python3 -m unittest tests.test_c2c_cli.C2CCLITests.test_run_claude_inst_outer_refreshes_peer_after_child_spawn tests.test_c2c_cli.C2CCLITests.test_run_claude_inst_outer_refresh_peer_uses_config_alias -v`
- `python3 -m py_compile run-claude-inst-outer`

## Follow-up

Watch future broker health reports for missing `storm-*` registrations. If they
recur, the next suspect is Claude MCP startup/session discovery rather than the
outer-loop child-pid refresh.
