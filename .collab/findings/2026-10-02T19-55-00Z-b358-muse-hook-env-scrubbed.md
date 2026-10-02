# B358 probe: muse hook env is scrubbed (managed identity invisible to hooks)

Date: 2026-10-02T19:55:00Z · Ticket: B358 (handoff) / B361 (follow-up) · Runner: B358 implementer
Target: muse 1.4.2-R4684.1. Closes the B355-REVIEW ASSUMPTION probe requirement.

## Verdict

`c2c hook muse` can NEVER see managed identity via env. The TUI process
carries `C2C_MCP_SESSION_ID`, but its SessionStart hook fires with NO
`C2C_*` and NO `MUSE_*` in env. The hook is therefore not the identity
authority for managed sessions (kimi-#40 consequence, different mechanism:
env scrubbing, not a shared daemon). B358 pre-registers pre-fork (identity
authority = launcher); B361 tracks the SessionStart adoption arm.

## Evidence (verbatim)

Setup: fake `XDG_CONFIG_HOME`/`XDG_DATA_HOME` under `/tmp/c2c-b358-probe`,
settings.json SessionStart hook dumping stdin + `C2C_*`/`MUSE_*` env, echo
TUI launched in tmux with `C2C_MCP_SESSION_ID=probe-sid-b358` +
`C2C_PROBE_MARKER=marker-1` exported in the pane shell, first turn
submitted via send-keys (SessionStart is lazy).

Hook dump (`hook-dump.log`):

```
=== FIRED: 2026-10-02T19:51:06Z ===
--- STDIN ---
{"cwd":"/tmp/c2c-b358-probe/work","hook_event_name":"SessionStart","model":"unknown","permission_mode":"default","session_id":"01a0fe2a-f99b-7e32-b1fe-d1f9bf86f2fc","source":"startup","transcript_path":null}
--- ENV(C2C|MUSE|PWD) ---
PWD=/tmp/c2c-b358-probe/work
```

TUI process env (same moment, `/proc/2438965/environ`):

```
C2C_MCP_SESSION_ID=probe-sid-b358
C2C_PROBE_MARKER=marker-1
```

Parentage: `2438965 2437952 ... muse-bin-1.4.2-R4684.1 --provider echo
--trust-workspace` — a DIRECT pane child, not a daemon. So kimi-#40's
daemon-parentage mechanism does NOT apply; muse scrubs (or never
propagates) its own env when spawning hook children.

## Consequences

1. `hook_muse_cmd` env-first resolution (B355) always falls through to the
   payload sid for managed sessions → SessionStart mints a COMPETING row
   (`registered_by=muse-hook`, native `01a0…` sid) beside B358's
   pre-registered `name` row (dual identity).
2. The SessionStart backlog drain serves the payload row, not the managed
   row; mid-session Stop/PostToolUse touch the payload sid, so the managed
   row's activity anchor misses too (rows decay at the #51 24h TTL).
3. B361 fix shape: SessionStart step 0 adopts a managed row by normalized
   cwd + live (pid, pid_start_time), then persists a
   payload-sid→managed-sid mapping for mid-session touch-through.
   Constraints: same-dir instances indistinguishable (bail loudly, kimi-#40
   limit); co-located vanilla TUI gets adopted (document); pid trust only
   via `C2c_pid_identity` (#85); exit 0 always.

## Severity

High for managed-muse correctness (identity split), but B358 ships
targeted: the managed row is addressable (send/poll/monitor work against
it) and the competing row is SessionEnd/retirement-cleaned. B361 closes
the drain/anchor gap.
