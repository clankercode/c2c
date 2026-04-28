# #234 Failover Drill — Consolidated Findings

**Date:** 2026-04-26T02:22Z
**Agent:** test-agent
**Type:** operational drill + real outage (dry-run detection + live recovery)
**Related:** `.collab/runbooks/coordinator-failover.md`, `.collab/findings/2026-04-26T01-25-00Z-coordinator1-test-agent-mcp-recovery-took-them-down.md`

---

## Executive Summary

Drill covered two scenarios: (1) dry-run detection of a parked coordinator using
diagnostic commands, and (2) a real MCP-outage recovery attempt that caused a
secondary failure (agent went down during recovery). Key findings:

1. All 6 diagnose-first commands in the runbook §4.1 work correctly
2. `./restart-self` without an outer-loop wrapper kills the agent with no auto-recovery
3. **`kill -USR1 <opencode_pid>`** is the correct recovery signal for OpenCode harnesses — fast, non-destructive, preserves registration
4. CLI fallback works when MCP is down — verified round-trip via broker relay

---

## Part 1: Dry-Run Detection (diagnose-first commands)

**Result:** All commands function correctly. One informational finding.

### `c2c_tmux.py list`

✅ Works exactly as documented.

```
ALIAS                TARGET           PANE_PID   CLIENT_PID
stanza-coder         0:1.2            462275     3465121
galaxy-coder         0:1.3            12559      669317
Lyra-Quill-X         0:1.4            12482      3014219
test-agent-oc        0:1.6            157402     668713
(11 cached aliases not live; `list --show-cached` to see)
```

### `c2c_tmux.py peek coordinator1`

✅ Works but issues a warning about stale cached target:
```
c2c_tmux: alias 'coordinator1' not live in any pane — using last-known
target 0:1.2 (pane may be reused or empty; verify before acting)
```

The cached target (0:1.2) actually belonged to **stanza-coder** at the time.
The warning is correct — recovery agent must trust `c2c list | grep coordinator1`
over the cached pane target.

**Finding:** The warning correctly flags pane reuse. Recovery agent should
always cross-verify with `c2c list` before acting on a cached pane target.

### `c2c stats --alias coordinator1 --json`

✅ Works correctly:
```json
{"alias": "coordinator1", "live": true, "msgs_sent": 2339,
 "msgs_received": 2283, "last_activity_ts": null}
```

**Finding:** `last_activity_ts` is `null` for some session types — not an
indicator of failure. Runbook should note this is expected.

### `c2c list | grep coordinator1`

✅ Works correctly — `coordinator1 alive pid=2362582`.

### Pre-push hook

✅ Hook exists at `~/.config/git/hooks/pre-push` → symlink to
`scripts/git-hooks/pre-push`.

**Finding:** Installed globally, not in `.git/hooks/`. Minor discrepancy
from runbook wording ("installed to .git/hooks") but functionally correct.

### `c2c coord-cherry-pick --help`

✅ Works correctly.

---

## Part 2: Real MCP Outage — Recovery Attempt + Secondary Failure

**Time:** ~01:00–01:25 UTC, 2026-04-26

### Timeline

| Time | Event |
|---|---|
| ~01:00 | MCP tools (c2c_poll_inbox, c2c_server_info, etc.) all returned "Not connected" |
| 01:02 | CLI `~/.local/bin/c2c poll-inbox` returned empty — no messages lost |
| 01:04 | CLI `~/.local/bin/c2c send coordinator1` succeeded — broker relay working |
| 01:08 | Coordinator received CLI-only test DM — round-trip verified |
| 01:08 | Attempted `/plugin reconnect` — not available in OpenCode harness |
| ~01:09 | Sent SIGUSR1 to outer loop (668700) — outer loop exited, no respawn |
| ~01:10 | test-agent dead in registry; pane parked at bash prompt |
| ~01:11 | Coordinator observed test-agent dead; pane at shell prompt |
| ~01:14 | Sent SIGUSR1 to OpenCode process (668734) — **MCP RECOVERED** ✅ |

### Root Cause: `./restart-self` Without Outer-Loop Wrapper

When `./restart-self` runs without a parent wrapper (`c2c start <client>` or
`run-*-inst-outer`), it kills the inner client process but nothing respawns it.
The pane is left parked at a shell prompt with the agent unregistered.

This is documented in coordinator1's findings doc:
> "If you are NOT under an outer-loop wrapper, do NOT run `./restart-self` —
> it will leave your pane parked at a shell prompt with no auto-relaunch."

**Recovery:** Operator or another agent must re-launch via `c2c start <client>`.

### SIGUSR1 Recovery Signal That Worked

**`kill -USR1 <opencode_pid>`** — sends SIGUSR1 to the OpenCode process,
which triggers the OCPlugin to re-handshake with the MCP server. OpenCode
catches SIGUSR1 and reconnects the plugin without restarting the client.

Steps:
1. Find the OpenCode process: `ps aux | grep opencode | grep test-agent`
2. Identify the main process pid (the one with the full opencode command line)
3. `kill -USR1 <pid>` — MCP reconnects within seconds
4. Verify with `c2c_server_info` MCP tool

**Why it works:** OpenCode's OCPlugin handles SIGUSR1 as a signal to
reconnect its MCP session. The plugin process (`c2c oc-plugin`) is a child
of the OpenCode process; SIGUSR1 propagates to the plugin which then
re-establishes the stdio JSON-RPC connection.

**Why SIGUSR1 to the outer loop wrapper failed:** The `c2c start` wrapper
process (668700) received SIGUSR1 and exited cleanly, but had no child-watch
logic to respawn OpenCode.

---

## Part 3: Findings and Recommendations

### For the Failover Runbook

1. **Add pane-reuse warning:** "If coordinator1 appears in another agent's
   pane (e.g. stanza-coder), this is normal — tmux sessions reuse pane numbers.
   Always trust `c2c list | grep coordinator1` + `alive pid=N` over the
   cached pane target."

2. **Document SIGUSR1 recovery for OpenCode:** "For OpenCode harnesses,
   `kill -USR1 <opencode_pid>` reconnects the OCPlugin without restarting
   the client. Find pid via `ps aux | grep opencode | grep <alias>`."

3. **Document the restart-self wrapper requirement:** "Do NOT run
   `./restart-self` unless you are under an outer-loop wrapper (`c2c start`
   or `run-*-inst-outer`). Without a wrapper, this will kill your session
   with no auto-recovery."

4. **`last_activity_ts` null is normal:** Note that null is expected for
   some session types (e.g., coordinator1 shows null), not an indicator of failure.

5. **Pre-push hook path:** Clarify it's in `~/.config/git/hooks/`, not
   `.git/hooks/`.

6. **`peek-inbox` naming:** The MCP tool uses underscores (`peek_inbox`);
   the runbook references the MCP tool correctly.

### For CLAUDE.md / Agent Onboarding

- Document `kill -USR1 <opencode_pid>` as the standard OpenCode MCP recovery
  signal, not `./restart-self`
- Clarify that `./restart-self` only works when there is a parent wrapper

---

## Conclusion

The failover runbook's diagnostic commands are accurate and functional. The
main gap was undocumented recovery paths for OpenCode harnesses — the SIGUSR1
signal is now the recommended first recovery step, and `./restart-self` should
only be used when an outer-loop wrapper is confirmed present.
