# Terminal E2E framework: legacy broker root + controller relay-send both broke live client tests

- **UTC:** 2026-06-26T09:40Z
- **Author:** (Max-driven session, docs-install-cmd worktree `e2e-pi-opencode-model`)
- **Severity:** High for the live terminal E2E suite (every `*_e2e.py` that
  uses `tests/e2e/framework`); these tests are env-gated so the rot was silent.

## Symptom

Live client smoke tests (`test_c2c_opencode_e2e.py`, and the new
`test_c2c_pi_e2e.py`) timed out at `scenario.wait_for(... _registered ...)` —
the client launched and stayed alive, but its registration never appeared in
the broker the test was reading.

## Root cause 1 — framework broker root used the rejected legacy path

`Scenario.broker_root()` resolved to `<workdir>/.git/c2c/mcp`. The c2c CLI and
the MCP server both run `C2c_repo_fp.resolve_broker_root` (`ocaml/c2c_repo_fp.ml`),
which now **ignores** a `C2C_MCP_BROKER_ROOT` pointing at a legacy
`.git/c2c/mcp` path and silently redirects to the canonical
`$XDG_STATE_HOME/c2c/repos/<fp>/broker` "to prevent split-brain":

```
[WARNING] C2C_MCP_BROKER_ROOT points to legacy .git/c2c/mcp path.
  Using canonical path to prevent split-brain.
```

So every client registered into the canonical XDG broker while the test kept
reading `<workdir>/.git/c2c/mcp` (never created). Discovered by launching a
real pi session: the pane showed `c2c: registered as <alias>` but the
intended broker dir did not exist; the alias was in the XDG canonical broker.

A custom broker path does NOT work for managed clients: **`c2c start opencode`
(and codex/kimi/claude) strips `C2C_MCP_BROKER_ROOT` from the inner client**, so
the embedded plugin resolves the canonical `$XDG_STATE_HOME/c2c/repos/<fp>/broker`
on its own regardless of what the env or `opencode.json` mcp.environment says.
(Proven: with the env set, opencode still registered at the canonical
`…/repos/<fp>/broker` at t≈4s.) pi (CLI path) DOES honor the env, but to make
ALL clients agree there is exactly one option.

**Fix:** `broker_root()` now resolves the **canonical** broker the same way
`C2c_repo_fp.resolve_broker_root` (OCaml) and the opencode plugin's
`resolveBrokerRoot` (TS) do — `$XDG_STATE_HOME/c2c/repos/<fp>/broker` with
`fp = sha256(remote.origin.url||toplevel)[:12]`. Every client registers there
naturally, the controller-side `c2c send` targets it, and the test reads it.
conftest removes the per-fp broker on teardown (fp is unique to the unique tmp
workdir, so deletion is safe).

## Root cause 2 — controller `send_dm` couldn't relay as another alias

After fixing the broker, `send_dm` (`c2c send --from <alias> ...`) failed:

```
refusing to send as '<alias>': that alias is registered to a different session than yours.
- To relay on behalf of another agent: set C2C_COORDINATOR=1.
```

The framework controller IS relaying on behalf of the agent. **Fix:** set
`C2C_COORDINATOR=1` in `send_dm`'s env when `--from` is used (the sanctioned
escape hatch, per CLAUDE.md pre-reset/coordinator notes). Also switched
`send_dm` to surface stderr on failure instead of a bare
`CalledProcessError` (the swallowed stderr is what made this hard to find).

## pi-specific — inbox is drained on delivery, so file-read assertions race

pi-c2c delivers inbound DMs into the session and DRAINS the broker inbox file
(inotify watcher + poll). `scenario.broker_inbox_contains()` therefore races
the drain and never sees the message. Probe confirmed: receiver pane rendered
`⧓ c2c.recv · ← <sender> · <token>` at t≈3s while `<alias>.inbox.json` was
already empty. `test_pi_smoke_send_receive` asserts delivery via the receiver
pane (`scenario.capture`) instead. (opencode keeps the file-read assertion —
it runs with `C2C_MCP_AUTO_DRAIN_CHANNEL=0`.)

## Status

- pi: `test_c2c_pi_e2e.py` — 3/3 PASS live (register, send/receive, model wiring).
- opencode: `test_opencode_smoke_with_agent` (register, model via role file) and
  `test_opencode_smoke_send_receive` PASS live after the canonical-broker +
  relay-send fixes.
- opencode: `test_opencode_smoke_model_override_reaches_inner_cmdline`
  (pre-existing) is environment-flaky — `c2c start opencode --agent X --model Y`
  repeatedly took the user's shared tmux server down ("no server running on
  /tmp/tmux-1000/default") during its 90s `wait_for_init`, so the test times
  out. A plain `tmux new-session` survives fine immediately after, and no OOM
  in dmesg — so it's specific to that launch combo, not systemic. The behavior
  it checks (`--model` reaches the inner cmdline) is covered deterministically
  by `test_opencode_adapter_builds_managed_launch_command_with_model`. FOLLOW-UP:
  investigate whether `--agent` + `--model` together wedge opencode/`c2c start`
  (the role-file model path, with-agent, is fine).
- The framework fixes (canonical broker, relay send) also unblock the
  codex/kimi/claude live tests (same managed-start broker behavior); not
  re-verified live here for lack of those binaries/quota this session.

## Repro / verify

```
# pi (passes):
C2C_TEST_PI_E2E=1 python3 -m pytest tests/test_c2c_pi_e2e.py -q --force-test-env
# model override (today = mimo-v2.5-pro, both clients):
C2C_E2E_MODEL=<id> ...   # or C2C_E2E_PI_MODEL / C2C_E2E_OPENCODE_MODEL
```
