# Findings Archive — 2026-04

## What is in here

Resolved/stale findings from the 2026-04 cycle. Originally 58 from the
early storm session (Apr 13-14). Folded in 2026-04-28 via #355 sweep:

- 42 SHA-confirmed RESOLVED / STALE-SCRATCH entries from 2026-04-14
  through 2026-04-27 (see
  `.collab/research/2026-04-28T04-30-00Z-coordinator1-findings-archive-sweep-plan.md`).
- 54 entries promoted up from the legacy `.collab/findings/archive/2026-04/`
  subdir (canonical archive root is `.collab/findings-archive/` per Max
  2026-04-28). 5 duplicates dropped.

## Why archived

- **Python-era issues**: The c2c broker, relay, and CLI were still primarily Python. Many findings describe bugs that were fixed during or after the OCaml port (cold-boot hook, MCP server, wire daemon, deliver inbox all migrated to OCaml).
- **PTY injection delivery**: Several findings describe PTY-injection based wake and delivery for Kimi, Crush, and Claude Code. PTY injection is deprecated; all delivery now uses broker-native paths.
- **Sweep dryrun gaps**: The `c2c sweep-dryrun` Python script was retired; OCaml `c2c sweep` now handles this natively.
- **Crush-related**: Crush is deprecated and no longer a first-class peer.
- **Kimi Nova worktrees**: The `kimi-nova` and `kimi-nova-2` worktrees were experimental harnesses that have since been retired.
- **Managed loop liveness**: Early探索 of Claude Code outer-loop management patterns, superseded by `c2c start` managed-instance system.
- **Duplicate PID ghost issues**: Many duplicate-PID findings from the Python registry era; the OCaml registry and sweep mechanism handle this differently.
- **Relay localhost/multi-machine tests**: Experimental relay tests from the early PTY-relay era, superseded by OCaml relay.ml.

## What was NOT archived (left in place)

- Findings from Apr 15 onwards (today is Apr 25)
- Findings tagged with current-agent aliases (galaxy-coder, jungle-coder, etc.)
- Findings describing issues that may still be partially relevant (e.g. alias hijack guard, session ID drift — some underlying issues may persist even if the specific manifestation changed)

## Categories archived

| Category | Count | Examples |
|---|---|---|
| PTY injection / wake | ~12 | kimi-steer-streaming-patch, kimi-idle-pts-inject-live-proof |
| Sweep dryrun gaps | 3 | sweep-dryrun-dispatch-gap, sweep-dryrun-duplicate-pid-blindspot |
| Crush deprecated | 3 | crush-dm-proof, crush-deliver-daemon-wrong-session |
| Python-era registry/broker | ~15 | storm-ember-pid-registration-staleness, broker-process-leak |
| Kimi Nova worktrees | ~15 | kimi-nova-kimi-wire-bridge-live-proof, kimi-nova-2-* |
| Claude wake delivery gap | 2 | claude-wake-delivery-gap, storm-beacon-claude-wake-delivery-gap |
| OpenCode plugin / managed loop | ~8 | opencode-plugin-drain-proven, opencode-managed-loop-liveness |
