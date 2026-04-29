# test-agent went offline during MCP-outage recovery

**Date:** 2026-04-26 ~11:25 UTC+10 (~01:25 UTC)
**Author:** coordinator1
**Severity:** medium
**Related:** #234 failover drill, `2026-04-26T01-08-00Z-test-agent-mcp-outage.md`

## Symptom

test-agent was responding via CLI fallback after their MCP-tools-down outage at ~11:03. By 11:25 they were `dead` in the registry (pid=668700 not alive) and `c2c send test-agent` returned "recipient is not alive".

Pane peek at `0:1.6`: bash prompt at `~/src/c2c master*`. Codex (MiniMax-M2.7-highspeed model) had exited. No outer-loop wrapper (`run-codex-inst-outer` etc.) was running, so no auto-restart.

## Root cause (probable)

test-agent attempted MCP recovery — most likely `./restart-self` after `/plugin reconnect` failed — and the restart took the whole inner client down without a wrapper to relaunch. CLAUDE.md `c2c start <client>` is the preferred managed-instance launcher; the old `run-*-inst-outer` scripts handle relaunch but were not in use here.

## Impact

- `#234` failover drill paused (the drill subject is themselves down).
- Build-break and slice-1 peer-PASS chain not affected — both already landed at master (599c5d2, fda7e13, 0990172).
- Cross-machine slice 2 dispatched to galaxy, slice 4 awaits lyra peer-PASS, docs-sweep batch distribution unchanged.

## Process gap

`./restart-self` is presented in CLAUDE.md as a valid recovery step but it has historically been unreliable across harnesses, and no documentation tells an agent that running it without an outer-loop wrapper means total exit. The failover runbook §Diagnosis section says "Coord at `Bash` prompt — claude exited; needs `./restart-self` by lyra in the coord's tmux pane" — which assumes the same restart-self being-broken pattern as we just hit.

Action items:
- Document on CLAUDE.md / failover runbook: "If you are NOT under an outer-loop wrapper, do NOT run `./restart-self` — it will leave your pane parked at a shell prompt with no auto-relaunch. Instead, exit cleanly and let the operator (or Max) relaunch via `c2c start <client>`."
- Consider: have `./restart-self` detect "no parent wrapper" and warn before running.

## Recovery

Pane is parked safely at shell. No uncommitted state in the working tree. When Max revives the slot with `c2c start <client>` test-agent will re-register and inbox queue will redeliver.
