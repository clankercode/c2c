# SPIKE: granular deliver-inbox/poker sidecar restart (go/no-go)

Date: 2026-07-20. Task: `P2.M3.E1.T002`. Branch: `task/p2-m3-e1-t002`.
Source under analysis: current `master` + worktree.
Source parent: `.collab/research/2026-07-20T01-10-09Z-i011-process-model-and-disruption.md`.
Author: pi sub-agent. NOT tested live — READ-MOSTLY spike only.

---

## Verdict: **CONDITIONAL GO**

`deliver` and `poker` are independently restartable without touching the inner
client. `notifier` (Kimi) is conditionally go — the dual-ownership race
(i011 findings) must be resolved first.

---

## Current architecture summary

Three sidecar types are tracked with pidfiles under the instance dir:

| Sidecar | pidfile | What it does | Targets |
|---|---|---|---|
| `deliver.pid` | `deliver_pid_path` | `start_deliver_daemon`: forks `c2c-deliver-inbox --client <x>` sibling watching the inner PID | Inner PID; reads broker independently |
| `poker.pid` | `poker_pid_path` | `start_poker`: forks a timer-based ticker that periodically sends a wake signal | Outer PID (`run_outer_loop`) |
| `notifier.pid` | `notifier_pid_path` | `C2c_kimi_notifier.ensure_daemon`: fork+setsid detached REST-polling daemon | Kimi server endpoint |

**Owner of all three**: `run_outer_loop` (the outer supervisor process for
Claude, OpenCode, Kimi, agy, Codex hooks). The app-server Codex owner has no
sidecars.

**Current restart behaviour**: `cmd_restart` sends `SIGTERM` to the inner
process group (killing deliver + poker as siblings), waits for the outer to
exit, captures orphan inbox, then `exec`s the replacement `c2c start`. The outer
SIGTERM handler (`cleanup_and_exit`) additionally calls `stop_notifier()`,
`stop_sidecar !deliver_pid`, `stop_sidecar !poker_pid` before exiting. Sidecars
are **always killed with the inner**; there is no current path to cycle a
sidecar independently.

**Kimi dual-ownership**: `c2c hook kimi` also calls `ensure_daemon`, so two
independent arms (outer supervisor + hook) can race on start/stop. The outer
teardown removes `notifier.pid` before the hook fires, leaving a pidfile-less
orphan (reproduced in i011).

---

## Granular restart analysis per sidecar

### 1. `deliver` — **GO (with invariants)**

**What it does**: `start_deliver_daemon` forks a `c2c-deliver-inbox` sibling
process. For agy it reads `agy-env.json` and calls bounded `agy agentapi
send-message` one-shots. For Codex hooks it watches the inner PID and calls
hooks on new mail. It reads the broker independently; it does not hold any
reference to the inner process beyond reading its PID.

**Dependencies on inner client**: None. The deliver daemon's only coupling to
the inner is the PID it monitors (for liveness), but even that is
informational — `c2c-deliver-inbox` drains the broker inbox regardless.

**What breaks if we kill it while inner is alive**: Nothing load-bearing.
Mail accumulates in the broker inbox during the cycle window. On restart it
resumes draining. This is the same window that already exists during a full
restart.

**What the granular restart would do**:
```
stop_sidecar !deliver_pid      # SIGTERM, 2s grace, SIGKILL, remove pidfile
clear_pidfile (deliver_pid_path name)
start_deliver_daemon ...       # re-fork new sibling, write new pidfile
```

**Implementation delta**: A new `cmd_restart_sidecar` entry point (or
`c2c restart <name> --sidecar-only`) that skips the inner kill, reuses the
inner PID from the existing config, and calls the same start functions. The
`cleanup_and_exit` partial path is already inlined for the exit-42 handler
(`c2c_start.ml:5821-5828`).

**Acceptable triggers**: Local operator command (`c2c restart-sidecar <name>
deliver`). MUST NOT be triggered by a peer message (B098).

---

### 2. `poker` — **GO (trivially)**

**What it does**: Periodic wake signal to the outer supervisor loop. Targets
`run_outer_loop`'s own PID. Only clients with `cfg.needs_poker = true` start
one.

**Dependencies on inner client**: None. Targets the outer, not the inner.

**What breaks if we kill it while inner is alive**: Nothing. The outer loop
keeps running. Poker is a keepalive mechanism, not a delivery path. The inner
client continues operating. On restart, the new poker resumes.

**Implementation delta**: Same pattern as deliver. Even simpler — poker targets
the outer PID which survives a sidecar-only restart.

**Acceptable triggers**: Local operator command. MUST NOT be triggered by a
peer message.

---

### 3. `notifier` (Kimi) — **NO-GO without dual-ownership fix**

**What it does**: `C2c_kimi_notifier.ensure_daemon` fork+setsid detached daemon
that polls the broker for mail and delivers via REST to the Kimi server.

**Dual-ownership race (i011 finding)**: Two independent callers invoke
`ensure_daemon`:
- `run_outer_loop` (supervisor arm): starts at launch, tracks pid in
  `notifier_pid`, writes `notifier.pid`
- `c2c hook kimi` (hook arm): also calls `ensure_daemon` when the Kimi
  SessionStart fires

On outer teardown, `stop_notifier()` removes `notifier.pid` and SIGTERMs the
tracked daemon. The hook arm fires *after* (or races with) this, finds no
pidfile, calls `ensure_daemon` which starts a new daemon with a *new pid* but
writes a new pidfile. The old outer has already exited so there is no
`notifier_pid` ref to track it → orphan.

**What breaks if we kill it while inner is alive**: Kimi delivery is
unavailable during the cycle. Mail accumulates in the broker inbox. On restart,
normal delivery resumes. Acceptable window similar to deliver.

**Granular restart would make dual-ownership worse** without fixing the race:
cycling the notifier from the outer creates the same gap that the hook exploits.

**Required pre-condition for GO**: Single durable owner. Recommended fix:
make the hook arm call a *signal* or *request* mechanism (e.g. write a flag
file + signal the outer) instead of directly calling `ensure_daemon`. The outer
is the sole owner and handles start/stop/respawn.

**Acceptable triggers (once dual-ownership is fixed)**: Local operator
command. MUST NOT be triggered by a peer message.

---

## Invariants that MUST hold for granular restart (any sidecar)

1. **B098 preserved**: No peer message (local broker inbox, relay-delivered,
   c2c envelope) triggers a sidecar restart. Only a local operator command or
   an owner-control request (app-server Codex pattern) may trigger restart.
2. **Inner client unaffected**: A sidecar-only restart does not signal or
   disrupt the inner client process group.
3. **Single durable owner per sidecar**: Exactly one process (the outer
   supervisor) owns the lifecycle of each sidecar. No second independent arm
   may start/stop/respawn a sidecar.
4. **No orphan sidecar**: After any restart path (full, partial, or crash),
   every tracked sidecar has a pidfile that corresponds to a live process
   *or* the sidecar is confirmed absent. No pidfile without a live notifier,
   no live notifier without a pidfile.
5. **Graceful cycle**: SIGTERM → wait → SIGKILL → new pidfile write is the
   safe sequence. A pidfile may not be written before the new process is
   confirmed forked.
6. **Message continuity**: Messages that arrive during the cycle window are
   preserved (broker inbox is append-only) and replayed when the new sidecar
   resumes. The orphan-inbox capture pattern from `cmd_restart` applies.
7. **Identity safety**: Stop/restart must never signal an unrelated process.
   The notifier uses comm-match (`c2c-kimi-notif`) for this; deliver and
   poker use PID ownership (outer is parent of both). The comm-match guard
   must be applied consistently if new sidecar types are added.

---

## Open questions and follow-ups if GO

### F1: Granular restart entry point
Should `c2c restart <name> --sidecar-only [deliver|poker|notifier]` be a flag
on the existing `cmd_restart`, or a separate `cmd_restart_sidecar` command?
Recommendation: separate command (`c2c restart-sidecar <name> <sidecar>`) to
keep the trust boundary explicit — sidecar-only restart is opt-in and cannot
accidentally trigger a full restart.

### F2: Restart while inner is active
`run_outer_loop` has no idle/active gate for the inner client. A sidecar-only
restart is safe regardless of turn state, but a future E-path idle gate
(`P2.M3.E1.T001` follow-up) would allow a *full* restart to be deferred until
the inner is idle. Sidecar-only restart does not need this gate.

### F3: Deliver daemon crashes
Today a crashed deliver daemon is not detected. A `stop_sidecar` + respawn on
SIGCHLD would make the deliver sidecar self-healing. The granular restart
command provides the manual counterpart.

### F4: Kimi dual-ownership fix (required for notifier GO)
The hook arm (`c2c hook kimi`) must not call `ensure_daemon` directly. Two
options:
- **Option A**: Hook writes a re-arm request file + signals the outer; outer
  handles the `ensure_daemon` call. Outer is the sole owner.
- **Option B**: Hook passes a flag (`--re-arm`) to a helper that delegates to
  the outer rather than calling `ensure_daemon` directly.

Option A is cleaner and aligns with the single-owner invariant.

### F5: CLI help text and operator-facing docs
`c2c restart-sidecar` must be documented with the trust model
(operator/local-only, not peer-triggerable).

---

## Implementation sketch (sidecar-only restart, excluding Kimi notifier)

```
let cmd_restart_sidecar (name : string) (sidecar : [ `deliver | `poker ]) : int =
  let cfg = load_config name in
  let pid, pid_path, start_fn =
    match sidecar with
    | `deliver ->
        (!deliver_pid, deliver_pid_path name,
         fun () -> start_deliver_daemon ~name ~client:cfg.client
           ~broker_root:cfg.broker_root ?child_pid_opt:None ())
    | `poker ->
        (!poker_pid, poker_pid_path name,
         fun () -> start_poker ~name ~client:cfg.client
           ~broker_root:cfg.broker_root ?child_pid_opt:None ())
  in
  stop_sidecar pid;
  remove_pidfile pid_path;
  match start_fn () with
  | Some new_pid ->
      (match sidecar with
       | `deliver -> deliver_pid := Some new_pid
       | `poker -> poker_pid := Some new_pid);
      write_pid pid_path new_pid;
      Printf.printf "[c2c restart-sidecar] %s restarted (new pid %d)\n%!" name new_pid;
      0
  | None ->
      Printf.eprintf "[c2c restart-sidecar] failed to restart %s for '%s'\n%!"
        (match sidecar with `deliver -> "deliver" | `poker -> "poker") name;
      1
```

Note: `deliver_pid` and `poker_pid` are closed-over refs in `run_outer_loop`;
the sketch above is for a new command that runs inside the outer loop process.
For an external `c2c restart-sidecar` command (runs from a separate process),
the pattern must be: read old pid from pidfile → stop via pidfile → restart
via a new outer process (exec path) or via a signal to the running outer.

For the external command case (more operator-friendly), the simplest path is:
`c2c restart-sidecar <name> deliver` sends SIGUSR1 to the outer, which handles
the cycle internally. This avoids splitting the pid-tracking across processes.

---

## Summary

- **deliver**: GO. Independently restartable; inner unaffected; orphan risk
  is the same as a full restart.
- **poker**: GO. Trivially safe; targets outer PID.
- **notifier (Kimi)**: NO-GO without F4 (dual-ownership fix). The race
  produces orphans; a granular restart would worsen the gap unless the hook arm
  stops calling `ensure_daemon` directly.
- **B098**: Preserved — any granular restart is an operator command, not a
  peer message trigger.
- **Follow-ups**: F1 (CLI entry point), F4 (Kimi dual-ownership), F3
  (self-healing deliver on SIGCHLD).
