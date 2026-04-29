# `c2c start kimi` runs TWO live kimi agents per managed instance

- **Date:** 2026-04-29 10:04 UTC
- **Filed by:** stanza-coder
- **Severity:** HIGH — root cause for two confirmed downstream symptoms; affects every kimi self-authored work item
- **Status:** OPEN — root cause traced, fix is design-level (not mechanical)
- **Sibling findings (downstream symptoms now explained by this):**
  - `2026-04-29T09-53-22Z-stanza-coder-kimi-tui-role-wizard-inadequate.md`
    (`ae671eb5`) — the wizard is fine; the wizard-output stub is irrelevant
    because the BG kimi self-authors anyway. Sibling re-classified as
    "minor wizard UX gap" (still worth fixing) instead of "load-bearing".
  - `2026-04-29T09-58-00Z-stanza-coder-kimi-self-author-attributes-to-slate.md`
    (`fedb23a2`) — the PATH gap is REAL but the missing-PATH belongs to the
    BG kimi's spawn site (in `c2c_wire_bridge.ml run_once_live` line 232,
    `Unix.create_process_env command argv (Unix.environment ())` inherits
    the wire-daemon's env, NOT the per-instance bin path). Fixing the
    PATH on that spawn fixes the slate-attribution; fixing **THIS** root
    cause makes the entire BG kimi go away.

## Summary

`c2c start kimi -n <alias>` does NOT, as one would naively assume, run
ONE kimi process per instance. It runs TWO live kimi agents, both
registered as the same alias, both polling the same inbox, racing to
drain and act on messages. One is the foreground TUI you see in the
tmux pane; the other is invisible to the operator but does most of the
agentic work — commits, peer DMs, tool calls.

This is not a transient race during message delivery (which would be
acceptable). It is **structural**: the wire-bridge architecture
synchronously spawns `kimi --wire --yolo` per delivery batch, and that
subprocess is a fully agentic kimi that processes the prompt to
completion (which can take minutes) before the wire-bridge tears it
down.

## Process tree (observed, both kimi instances)

```
fish (parent shell)
└── c2c start kimi -n lumi-tyyni  (3633138, outer wrapper)
    ├── Kimi Code (3633153)         ← FOREGROUND TUI (visible in tmux)
    │       └── c2c-mcp-server child, MCP session "lumi-tyyni"
    │
    └── c2c start kimi -n lumi-tyyni  (3633154, ARGV-INHERITED FROM
        │   PARENT — actually running C2c_wire_daemon.start_daemon's
        │   forever loop, NOT c2c-start logic. Pstree mislabels it.)
        │
        └── Kimi Code (3639999)     ← BACKGROUND kimi (invisible)
                └── c2c-mcp-server child, MCP session ALSO "lumi-tyyni"
```

The "sibling `c2c start kimi` process" (PID 3633154 above) is **not**
a recursive `c2c-start` invocation — it's the wire-daemon's forked
child. The fork at `c2c_wire_daemon.ml:85` does not `execve`, so the
child inherits the parent's argv (`c2c start kimi -n lumi-tyyni`) and
appears in `ps`/`pstree` under that command line, even though it's
actually running `start_daemon`'s `while true do … run_once_live …
done` loop.

## Root cause (confirmed)

1. **`c2c_start.ml` line 4074-4079** — when launching kimi, the outer
   wrapper calls `start_wire_daemon` after the inner kimi (FG TUI) is
   running.

2. **`c2c_wire_daemon.ml:76-127` `start_daemon`** — `Unix.fork ()`,
   child becomes session leader, enters infinite loop:
   ```ocaml
   while true do
     C2c_wire_bridge.run_once_live
       ~broker_root ~session_id ~alias ~command ~work_dir;
     Unix.sleepf interval (* 5.0 sec *)
   done
   ```

3. **`c2c_wire_bridge.ml:212-275` `run_once_live`** — every iteration
   that has pending messages:
   ```ocaml
   let argv = [| command; "--wire"; "--yolo"
               ; "--work-dir"; work_dir
               ; "--mcp-config-file"; tmp_config |] in
   let pid = Unix.create_process_env command argv
              (Unix.environment ()) ... in
   wire_prompt wc (format_prompt ~role_lookup messages);
   ```
   That spawns a SECOND, fully-agentic kimi process (with its own
   c2c-mcp-server child) and blocks on `wire_prompt` until the
   subprocess returns its prompt response. The MCP config file
   has `C2C_MCP_AUTO_REGISTER_ALIAS=<alias>`, so the subprocess
   registers as the same alias and starts draining the inbox
   independently.

4. **`wire_prompt` blocks for the entire duration of the kimi
   subprocess's task** — a "draft your own role file" prompt
   takes 30s-3min, during which the BG kimi runs unrestricted:
   tool calls, git commits, DM sends, all attributed to the
   alias but happening in a process the operator cannot see.

5. **The `Fun.protect ~finally` cleanup** does try to enforce a
   15s deadline + sigkill, BUT the deadline starts AFTER
   `wire_prompt` returns (i.e. after the subprocess has finished
   the work). So the BG kimi naturally lives for as long as the
   prompt takes; the deadline is only a safety net for genuinely
   stuck subprocesses.

## Why this is HIGH severity

- **Two-agents-one-alias** breaks identity invariants. Anything that
  assumes "alias X = single agent" (peer-PASS trust, send-memory
  handoff routing, audit lineage) is wrong by 2x.
- **Operators have no visibility into BG-kimi's work.** No transcript,
  no tool log, no prompt history. If the BG kimi misbehaves
  (commits secrets, sends a wrong DM), the operator cannot inspect
  what happened — only `c2c history` after the fact.
- **Race conditions on inbox draining** mean DM delivery latency is
  unpredictable. Lumi reported 4-min latency on a sibling-check DM
  to kuura because the BG kimi was tied up authoring its own role
  file and didn't drain until that completed.
- **Author leak (sibling finding `fedb23a2`) is a direct consequence**:
  the BG kimi's PATH lacks the per-instance shim, so all its commits
  attribute to `slate-coder`. Fix this finding's root cause and
  the author leak goes away (no BG kimi → no broken-shim spawn).
- **Sustained workload makes it worse.** Every new DM that triggers
  the wire-daemon spawns a new kimi-subprocess. If the FG kimi is
  busy (or absent — operator stepped away), the BG kimi makes the
  decisions. Multi-DM pile-up could spawn multiple BG kimis if the
  loop iteration interval is shorter than task completion time
  (5s loop vs 30-180s task — race-window is real).

## Reproduction

```
# Spawn a kimi
c2c start kimi -n probe-double-spawn  # in a fresh tmux pane

# DM it something the agent will act on (anything substantive — a draft
# task, a review, a code question)
c2c send probe-double-spawn "draft a 50-word agent self-introduction"

# Wait ~20s, then enumerate processes:
pstree -p $(pgrep -of "c2c start kimi -n probe-double-spawn")

# Observed: TWO `Kimi Code` python processes, both children of an
# `c2c start kimi` ancestor chain. One is the TUI; one is the
# wire-bridge subprocess. Both have a `c2c-mcp-server` child.
```

## Recommended fixes

### Design call (coordinator + Max needed)

The wire-bridge architecture has an inherent tension: kimi has no
"inject text into running TUI session" API (unlike Claude Code's
PostToolUse hook or OpenCode's plugin), so the workaround was to
spawn an ephemeral kimi-wire-RPC subprocess to relay messages. But
the kimi-wire-RPC subprocess is not actually ephemeral — it's a full
agentic instance that processes the prompt to completion before
exiting.

Three branches:

**Option A — Make the wire-bridge actually ephemeral (preferred).**
The kimi-wire-RPC subprocess should ONLY render the prompt into the
FG TUI's message stream, not act on it. This requires either:
- A kimi flag/mode that says "render-only, do not engage tool loop"
  (would need to be added to kimi-cli upstream — out of scope for
  c2c), OR
- A different delivery mechanism: write the message to a file the
  FG TUI watches, or use kimi's session resume to inject the
  message into the existing session.

**Option B — Make the wire-bridge non-blocking + single-shot per
DM (concession).** Spawn a kimi-subprocess per delivery, let it
register/process/exit naturally, but DO NOT consider the BG kimi
the canonical agent. Add a broker-level guard that REFUSES a
second registration for the same alias while one is alive (or
dedupes them transparently). This keeps the model "one agent per
alias" even though the implementation forks.

**Option C — Drop the wire-bridge for kimi, use a different
delivery mechanism.** Examples: kimi `/loop`-equivalent if one
exists; a notification daemon that polls inbox and writes to a
file the FG TUI watches; a stdin pipe into the running kimi
process. Each has its own trade-offs.

Without a coord-level decision on direction, I cannot ship a
mechanical fix here.

### Mechanical fix (if Option B is chosen)

`c2c_mcp.ml` `Broker.register` could add an alias-collision check:
if alias is already alive AND new session-id differs, refuse the
new registration with a clear error. The wire-bridge would then
need to register as a transient session-id (e.g. `<alias>-wire-<ts>`)
and authenticate by carrying the canonical alias's signing key.
This is non-trivial.

### Quick mitigation (no fix, just visibility)

Until the design call is made: log every wire-bridge spawn at
HIGH visibility — emit a broker.log audit line `kimi_wire_spawn`
with the parent FG kimi's pid + the spawned wire-kimi's pid + the
delivery batch size. Operators can then at least see "the BG kimi
is taking action right now" by tailing broker.log.

## Holds in effect (per coord1's call 2026-04-29 20:02 UTC)

1. **Both kimis stopped** (`c2c stop kuura-viima` + `c2c stop
   lumi-tyyni`) — confirmed alive=false.
2. **Node 3 (`vesi-kivi`) held indefinitely** until launch path is
   fixed.
3. **kuura↔lumi peer-PASS verification slice held** — would test
   on a known-broken launch path, results invalid.

## Cross-references

- Sibling findings (downstream symptoms):
  - `ae671eb5` — `2026-04-29T09-53-22Z-stanza-coder-kimi-tui-role-wizard-inadequate.md`
  - `fedb23a2` — `2026-04-29T09-58-00Z-stanza-coder-kimi-self-author-attributes-to-slate.md`
- Code references:
  - `ocaml/c2c_start.ml:4074-4079` — `start_wire_daemon` call site
  - `ocaml/c2c_start.ml:3236-3245` — `start_wire_daemon`
  - `ocaml/c2c_wire_daemon.ml:76-127` — `start_daemon` fork loop
  - `ocaml/c2c_wire_bridge.ml:212-275` — `run_once_live` subprocess spawn
- Affected commits (confirmed misattributed via this mechanism):
  - `cb740ecf` (lumi-tyyni's role file, attributed to slate-coder)
  - `664c2281` (kuura-viima's role file, attributed to slate-coder)

## Status: OPEN

Root cause confirmed. Mechanical fix is gated on a design decision
(option A/B/C above). Filed and held pending coord1 + Max review.
Holds enforced. No further kimi work until cleared.
