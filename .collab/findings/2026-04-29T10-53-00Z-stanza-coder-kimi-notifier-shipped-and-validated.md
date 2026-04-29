# Kimi notification-store delivery — SHIPPED + validated

- **Date:** 2026-04-29 10:53 UTC
- **Filed by:** stanza-coder
- **Severity:** RESOLVED — closes finding `b6455d8e` (root cause)
- **Status:** SHIPPED — Slices 1+2 cherry-picked to master at commits
  `f27929ad` (deprecate wire-bridge) + `642f6b63` (C2c_kimi_notifier)
- **Cross-references:**
  - Root-cause finding: `b6455d8e` (`c2c-start-kimi-spawns-double-process.md`)
  - Sibling findings now SUPERSEDED: `ae671eb5` (role wizard, downstream symptom),
    `fedb23a2` (slate-author leak, downstream symptom)
  - Probe-validated design: `.collab/research/2026-04-29T10-27-00Z-stanza-
    coder-kimi-notification-store-push-validated.md`
  - Runbook (operator-facing): `.collab/runbooks/kimi-notification-store-delivery.md`

## Summary

The kimi-as-peer dual-agent root cause is fixed. Two slices shipped:

- **Slice 1** (`f27929ad`): set `needs_wire_daemon = false` in both kimi
  `client_config` sites (clients hashtable + `KimiAdapter` module). Kimi
  was the only consumer of the wire-bridge machinery, so this makes
  `c2c_wire_bridge.ml` + `c2c_wire_daemon.ml` unreachable code — scheduled
  for cleanup deletion in the follow-up slice this finding is filed under.
- **Slice 2** (`642f6b63`): new `C2c_kimi_notifier` module — drains broker
  inbox, resolves the kimi TUI's active session-id by parsing kimi.log,
  writes `event.json` + `delivery.json` into the kimi session's notification
  store, and tmux send-keys-wakes the pane when idle. 270 + 50 LoC, 5/5
  unit tests pass.

## Validation record (dogfood smoke 2026-04-29 20:52 UTC)

Spawned `c2c start kimi -n kn-smoke` in tmux pane `0:2.4`. Sent one DM
from this stanza-coder session via `mcp__c2c__send`. Observed:

| Checkpoint | Pre-fix behaviour | Observed after Slice 2 | Status |
|---|---|---|---|
| Kimi process count | TWO `Kimi Code` python processes per spawn (FG TUI + wire-bridge subprocess) | ONE `Kimi Code` (PID 548308) — the FG TUI | ✅ |
| Notifier daemon | Wire-bridge daemon (problematic) | `c2c_kimi_notifier` daemon up, pid in `~/.local/share/c2c/kimi-notifiers/kn-smoke.pid`, log: `[kimi-notifier] delivered 1 message(s)` | ✅ |
| Notification on disk | N/A (wire-bridge didn't use notification store) | `~/.kimi/sessions/f331b46a50c55c2ba466a5fcfa980fc2/3f29c085-cda5-49c8-951e-3752a5417545/notifications/<id>/{event.json,delivery.json}` written; session-id matches kimi TUI banner exactly (`resolve_active_session_id()` worked) | ✅ |
| Toast in TUI | None (BG kimi consumed message invisibly) | Bottom of pane: `[c2c-dm] c2c DM from stanza-coder` (within ~3s of write) | ✅ |
| Agent context | Never injected (BG kimi was the agent that "saw" the message; FG TUI sat idle at 0.0% context) | Context jumped 0.0% → 10.9% (28.5k tokens). Agent woke from idle, ingested the notification, and prompted for `poll_inbox` permission to act on it | ✅ |
| Clean shutdown | Orphan-survivor cascade (BG kimi + grandchildren survived `c2c stop`, kept registering and acting under the alias) | `c2c stop kn-smoke` → all processes terminated cleanly. Verified: `ps -eo pid,cmd | grep "Kimi Code"` returned empty | ✅ |

**6/6 checkpoints pass.** Each was a load-bearing concern in the prior
finding chain.

## Architecture changes that landed

1. **Wire-bridge fully deprecated for kimi.** Both `client_config`
   `needs_wire_daemon = false`. The wire-bridge code itself
   (`c2c_wire_bridge.ml`, `c2c_wire_daemon.ml`, `start_wire_daemon` helper)
   stays in tree as dead code; the cleanup slice this finding is filed
   under will delete the modules + the `c2c wire-daemon` CLI subcommand
   group + the `Kimi_wire` capability variant.

2. **New module `C2c_kimi_notifier`** (270 LoC `.ml` + 50 LoC `.mli` + 100
   LoC alcotest):
   - File-based push via `event.json` + `delivery.json` JSON files
   - Notification ID = deterministic 12-char md5 hex of
     `from_alias|ts|content` → safe write-and-retry semantics, kimi
     de-dupes via `dedupe_key` field
   - Session-id discovery via parsing `~/.kimi/logs/kimi.log` for the
     most recent `Created new session: <UUID>` line; regex anchored,
     runbook anchor at
     `.collab/runbooks/kimi-notification-store-delivery.md§"session-id-discovery"`
   - Workspace-hash `md5(work_dir_path)` matches kimi-cli verbatim
     (`metadata.py:WorkDirMeta.sessions_dir`)
   - Tmux send-keys idle-detection heuristic + wake-prompt; falls *open*
     (assumes idle on capture failure) per coord guidance
   - Daemon shell: fork + setsid + pidfile + SIGTERM-with-grace-then-SIGKILL

3. **Wire-up in `c2c_start.ml`**: kimi-notifier branch fires on
   `client = "kimi"` right after the (now-dead-for-kimi)
   `start_wire_daemon` site. `TMUX_PANE` env var captured for the wake
   target; absent → no wake (toasts still work).

## Why this matters

The root-cause finding `b6455d8e` documented four symptoms:
1. **TUI invisibility** — operator couldn't see what the agent was doing
2. **DM delivery latency races** — drained-by-BG vs displayed-by-FG mismatch
3. **slate-coder author misattribution** — BG kimi's PATH lacked the
   per-instance shim (commits cb740ecf + 664c2281 still misattributed)
4. **Orphan-survivor cascade on `c2c stop`** — BG kimi detached from the
   tracked process tree; survived sigterm; kept acting

All four are GONE post-Slice 2. **Kimi-as-peer parity with Claude is now
real.** The kimi delivery path mirrors Claude's PostToolUse-hook +
`<c2c>` channel-injection model, just file-backed instead of
hook-callback-backed.

## Outstanding work (this slice)

Per the docs-audit subagent's report (2026-04-29 ~20:33):

- **~16 BLOCKER doc edits** across 10 files (`docs/MSG_IO_METHODS.md`,
  `docs/commands.md`, `docs/known-issues.md`, `docs/client-delivery.md`,
  `docs/clients/feature-matrix.md`, `docs/communication-tiers.md`,
  `docs/index.md`, `docs/get-started.md`, `docs/overview.md`, `llms.txt`,
  `README.md`)
- **~1000 LoC code+CLI removal**: `c2c_wire_bridge.ml`,
  `c2c_wire_daemon.ml`, `test_wire_bridge.ml`, the `c2c wire-daemon`
  Cmdliner group + tier registry entries, `Kimi_wire` capability variant
- **MED-tier housekeeping**: deprecation banners on 2 superpowers specs +
  RESOLVED footers on 6 historical findings; Migration matrix updates;
  c2c_capability rename; comment-list updates
- **LOW-tier**: todo.txt obsolete entries; tmp_status.txt cleanup

This slice ships the load-bearing pieces (new runbook + this finding +
a representative subset of the BLOCKER doc updates). Deeper code-deletion
of wire-bridge modules is intentionally deferred to a Slice 4 — once we
have a few days of bake on the notifier in production, deleting the
fallback code becomes safer.

## Closing note

The kimi bring-up that started this session was meant to be a 30-minute
spin-up. It became a deep-architecture refactor, three findings, two
slices, and a new delivery primitive. That's the dogfood loop working
as designed: real use surfaced a fundamental bug that had probably been
silently misattributing every kimi-authored commit since the wire-bridge
landed. The fix unblocks kimi-as-peer for the rest of the swarm.

🪨🌬️ — stanza-coder
