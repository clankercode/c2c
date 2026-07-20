---
title: "I011-H SPIKE: extract Codex app-server deliver loop into ledger-backed sidecar"
date: 2026-07-20T12:50:00+10:00
author: pi-3b6265-a3a9330
severity: spike
status: NO-GO
task: P2.M3.E1.T001
branch: task/p2-m3-e1-t001
parent-link: P2.M3.E1 (managed Codex delivery architecture)
inputs:
  - .collab/research/2026-07-20T01-10-09Z-i011-process-model-and-disruption.md
  - .collab/findings/2026-07-20T00-47-59Z-codex-i010-codex-restart-stale-live-proof.md
  - ocaml/c2c_codex_deliver_loop.ml
  - ocaml/c2c_codex_session.ml
  - ocaml/c2c_codex_app_server.ml
---

# SPIKE: Codex App-Server Deliver Loop Sidecar Extraction

## GO / NO-GO: NO-GO

The current inline design is already ledger-backed and restart-resilient.
Extraction adds cross-process complexity, IPC overhead, restart coordination
surface, and B098 interaction risk — without solving a demonstrated functional
gap. The apparent "sidecar gap" is a classification artifact, not a defect.

---

## Rationale

### What "sidecar" means in this codebase

Across the managed set, "sidecar" has two distinct shapes:

1. **Outer-owned detached process** — e.g. Kimi notifier, agy deliver inbox,
   OpenCode plugin monitor. These watch an **unstructured** target (a PID, an
   env file, a session index). They exist because the inner CLI has no API
   surface: the sidecar must poll/discover the binding from the outside.

2. **Ledger-backed state machine with a process boundary** — e.g. the
   relay connector. Ledger + IPC. The process boundary is load-bearing because
   the component must survive the parent process dying.

The Codex deliver loop is **neither**. It is an **inline co-process** inside
the owner launcher, not a detached monitor. It is bound to the app-server unit
lifetime deliberately (not accidentally), and it is already **ledger-backed**:

- T003 inject ledger: `~/.c2c/repos/<fp>/broker/ingress/<session>.ledger.json`
- T007 turn ledger: `~/.c2c/repos/<fp>/broker/turn/<session>.ledger.json`

Both persist to disk under the broker root, keyed by `session_id` (stable across
restarts). The `on_thread_discovered` binding also persists to
`codex-delivery-status.json` under the instance dir.

### I010 restart proof (A proof inputs)

I010 (`i010-codex-restart-stale-live-proof`) demonstrates exactly-once
delivery across a forced `--force restart-stale` of a Codex app-server owner:

- Owner PID unchanged through `execve`
- Server + frontend replaced (new generations)
- Thread ID identical across both ledgers
- Ingress ledger: 1 entry for pre-restart message, `state=injected`,
  `retry_count=0`
- Auto-turn ledger: 1 batch for pre-restart message, `turn_done`
- Post-restart message similarly recorded once
- Model visible both DATA markers

The deliver loop **did not break** during restart. It re-entered the loop,
re-loaded the same thread_id, and continued. This is the architecture working
correctly.

### I011 disruption audit (D audit inputs)

The D audit found:

> Default Codex still couples delivery-loop replacement to server/frontend
> replacement, but it now has a safe same-pane owner-control restart and exact
> thread continuity.

Section H of the audit says:

> H — sidecar extraction: prioritize removing the Kimi hook/outer dual-arm
> ambiguity and giving every detached process one durable owner.

"H" explicitly scopes the action to **detached processes** with dual-arm
ownership problems (Kimi's notifier is the concrete case). It does not mandate
turning the Codex inline deliver loop into a detached sidecar.

The deliver loop does **not** have a dual-arm ownership problem. The launcher
owns it exclusively. The ledger is the durable artifact, and the loop is a
best-effort driver bound to the unit lifetime.

### What extraction would require

| Concern | Current (inline) | Extracted sidecar |
|---|---|---|
| Token provider | Direct closure access (launcher owns handle, token lives in memory) | IPC to sidecar or shared memory; token is secret |
| Thread discovery | Direct closure (`thread/loaded/list` via launcher) | IPC to sidecar or sidecar probes directly |
| Ingress client | In-process WS control channel to app-server | Sidecar probes WS; launcher must not conflict |
| Restart coordination | Owner self-reexecs; loop re-enters on same thread | Sidecar must detect restart, re-acquire handle, drain stale state |
| Broker root access | Direct (same process) | Shared path or IPC |
| B098 enforcement | Same process (T003/T007 own the gates) | Sidecar must not widen the message→action surface |

Every one of these is solvable, but every one adds **coordination surface**
that does not exist today. The current design is simpler and already correct.

### B098 preserved

B098 ("bus, never RPC") applies to **messages** — c2c mail is DATA, not an
RPC call. The deliver loop is an **in-process driver** for T003/T007, not a
message bus. Extracting it to a sidecar would not change B098. However, the
sidecar would need to communicate with the app-server over the control channel,
which is an internal API — not a c2c message surface. No change to B098
invariants is required or warranted.

---

## Why "GO" was tempting

The apparent asymmetry — every other managed client has a detached deliver
sidecar, Codex does not — suggests a gap. But the asymmetry is **correct**:

| Client | Target | Has API? | Needs sidecar? |
|---|---|---|---|
| Kimi | REST prompt-inject endpoint | Yes | Notifier is detached for resilience |
| agy | agentapi endpoint | Yes | Deliver sidecar is detached watcher |
| OpenCode | Plugin API (in-process) | In-process | Plugin children are inner-owned |
| Codex hooks | Hook boundary | No | Detached watcher needed |
| **Codex app-server** | **Control WS channel** | **Yes (in-process)** | **Inline driver sufficient** |

The Codex app-server exposes the control channel **in-process** via the
launcher's handle. There is no external endpoint to reach; the loop drives the
same-process WS client directly. A detached sidecar would have to either:

1. Hold its own WS connection to the app-server, duplicating auth state, **or**
2. Communicate with the launcher via IPC, adding a coordination layer

Neither is simpler than the current inline design.

---

## Follow-up backlog tasks (if GO were ever revisited)

Since NO-GO, these are documented for the record if future evidence changes the
 calculus:

### F1: Kimi hook/outer dual-arm disambiguation (the real H action)

The I011 audit's "H" item is about **Kimi's notifier** having two owners
(outer + hook arm). That is the demonstrated dual-arm problem. Fixing it
requires:

- Clarify which arm owns the notifier lifecycle
- Ensure the hook arm cannot orphan a daemon after outer teardown
- Possibly make the hook arm idempotent with the outer arm

This is the correct prioritization of the "H" label.

### F2: Document why Codex app-server has no detached deliver sidecar

A note in `c2c_codex_deliver_loop.mli` or the design docs explaining that
the inline co-process design is intentional and that the ledger already provides
restart resilience. This would prevent future confusion about why Codex differs
from Kimi/agy.

### F3: Spike: ledger durability stress test

Before any extraction work, run a deliberate crash test:
`kill -9` the Codex owner during a live delivery pass, verify:
- Both ledgers recover cleanly on restart
- No duplicate injection of queued messages
- Thread binding survives

If this test passes (it likely does), it confirms the ledger is the durable
artifact and the loop is correctly stateless-between-passes.

---

## Conclusion

The deliver loop extraction spike is **NO-GO for now**. The current inline
ledger-backed design is correct, proven, and simpler than an extracted sidecar.
The I011 "H" label correctly applies to the Kimi notifier dual-arm problem,
not to Codex. The apparent asymmetry between Codex and other clients is an
expected consequence of Codex exposing an in-process API where others need
external polling.

**B098 is preserved.** No message surface is changed. The deliver loop remains
an in-process T003/T007 driver. If future evidence (e.g. a specific failure
mode where the inline loop loses state during a crash that the ledger does not
recover) emerges, F3 provides a concrete validation step before reconsidering
extraction.
