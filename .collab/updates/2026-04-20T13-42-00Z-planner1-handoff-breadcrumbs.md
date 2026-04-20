# planner1 handoff breadcrumbs

**Written:** 2026-04-20T13:42Z (pre-emptive, before any restart decision)
**Author:** planner1 (in-flight session at tmux 0:1.4)

If my session is restarted (as guinea-pig for the d4413bd SIGCHLD fix
test), the next planner instance should pick up here.

## Session context

- User ran `/loop 4m Check mail and continue with tasks` at session start.
- I switched cron to `3-59/4 * * * *` (job id `70bb0e9e`, in-memory)
  per coordinator1's stagger request. **That cron dies on restart.**
  A fresh planner needs Max to re-issue `/loop` (same offset, please).
- Alias: planner1. Session has 15 sent / 14 recv at 13:42Z.

## In-flight work status

1. **Smoke-test runbook** — DONE, committed at 6c14440
   (`.collab/runbooks/c2c-delivery-smoke.md`). All four coordinator1
   fixups applied (hook grep, mcp-server staleness, §4b hedge,
   §1 verification).

2. **scripts/c2c-swarm.sh test report** — DONE, DM'd coordinator1 at
   13:26Z. Concrete finding: all four live panes (coder1 101,
   coder2-expert 193, planner1 107, coordinator1 176) had ECHILD
   hits in scrollback — evidence the plugin hooks.json cache patch
   wasn't taking effect on running sessions. Led to
   d4413bd (SIGCHLD SIG_DFL) as the real root-cause fix by
   coder2-expert.

3. **Task #4 (relay plan doc)** — PREP ONLY. Not started. Coordinator1
   said hold until smoke-test passes. Key context banked:
   - Read `docs/c2c-research/e2e-encrypted-relay-architecture.md`
     end-to-end — recommends Ed25519 identity + X3DH + Double
     Ratchet (via libsignal) + Megolm Sender Keys for rooms +
     WebSocket/TLS 1.3, phased 4-step rollout.
   - Existing code surveyed: `c2c_relay*.py` (9 modules, ~2.9k LOC,
     Python HTTP relay + sqlite persistence) and `ocaml/relay.ml`
     (827 LOC, in-memory OCaml relay with Cohttp_lwt_unix).
   - Existing CLI: 7-subcommand shell-out bridge at
     `c2c relay {serve,connect,setup,status,list,rooms,gc}` per
     finding `2026-04-15T00-50-00Z-dev-ceo-ocaml-relay-cli-bridge.md`.
   - Deliverable will be `docs/c2c-research/relay-internet-build-plan.md`
     mapping each phase to concrete slices in existing code. Plan
     only, no coding.

4. **Guinea-pig restart ACK** — DECLINED in-session to coordinator1 with
   three reasons (cron dies, c2c start has no --resume, coder1 better
   candidate). New data since then: d4413bd is the actual root-cause
   fix, not a patch, and makes the restart case much stronger — but
   **explicit user (Max) consent required** to end his /loop session.
   I'd re-read as ACK-gated-on-Max, not a hard no.

## Immediate next steps for planner2

1. Poll inbox. Pick up anything queued in the ~N minutes I was down.
2. Ask Max to re-/loop if not already done.
3. Check coordinator1's status — they were going to do coder1 →
   coder2-expert → coordinator1 sequential restarts after me.
4. If smoke-test is confirmed passed post-restart-cascade, start
   drafting `docs/c2c-research/relay-internet-build-plan.md`.

## Cron stagger (keep this)

| Offset | Alias          | Cron             |
|--------|----------------|------------------|
| 0,4,8  | coordinator1   | `*/4 * * * *`    |
| 1,5,9  | coder1         | `1-59/4 * * * *` |
| 2,6,10 | coder2-expert  | `2-59/4 * * * *` |
| 3,7,11 | planner1       | `3-59/4 * * * *` |
