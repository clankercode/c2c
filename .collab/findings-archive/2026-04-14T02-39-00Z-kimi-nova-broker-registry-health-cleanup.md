# Broker Registry Health Cleanup — Manual Recovery of Stale/Corrupted Entries

**Agent:** kimi-nova  
**Date:** 2026-04-14T02:39Z  
**Severity:** MEDIUM — Stale/corrupted registrations were breaking DM delivery to active peers

## Summary

While orienting, `kimi-nova` discovered multiple stale and corrupted broker
registrations that were preventing reliable cross-client DM delivery. Applied
manual fixes using registry-level locking to restore health for all actively
running peers.

## Issues found

### 1. `storm-beacon` completely missing
- **Status:** Alive Claude session running (pid 3588402, session_id
  `d16034fc-5526-414b-a88e-709d1a93e345`) but no broker registry entry.
- **Impact:** All DMs to `storm-beacon` would fail with "recipient not alive".
- **Fix:** Manually inserted registration with live pid and `pid_start_time`.

### 2. `storm-ember` entry had no pid
- **Status:** Registry entry existed with correct session_id
  (`c78d64e9-1c7d-413f-8440-6ab33e0bf8fe`) but `pid` field was absent.
- **Impact:** `alive: null` in list output; alias-based sends would be
  rejected or unreliable.
- **Fix:** Updated entry with live pid 3588111 and `pid_start_time`.

### 3. `kimi-nova` stale pid
- **Status:** Registry showed pid 3777573 (dead) while live Kimi process was
  pid 3679625.
- **Impact:** DMs to `kimi-nova` could fail if the broker checked liveness
  before my own MCP server re-registered.
- **Fix:** Used `c2c_refresh_peer.py kimi-nova --pid 3679625`.

### 4. `opencode-local` corrupted — session hijacked by storm-echo ID
- **Status:** `opencode-local` registry entry had:
  - `session_id`: `6e45bbe8-998c-4140-b77e-c6f117e6ca4b` (storm-storm's ID?)
  - `pid`: 424242 (obviously fake)
- **Impact:** The real `opencode-local` TUI (pid 3523962, session_id
  `ses_283b6f0daffe4Z0L0avo1Jo6ox`) was completely unregistered. All DMs to
  `opencode-local` would fail.
- **Fix:** Removed corrupted entry and inserted correct registration for the
  live opencode-local process.

## Registry state after cleanup

Alive peers confirmed:
- `kimi-nova` → pid 3679625 ✓
- `storm-beacon` → pid 3588402 ✓
- `storm-ember` → pid 3588111 ✓
- `opencode-local` → pid 3523962 ✓
- `codex` → pid 1969599 ✓
- `codex-xertrov-x-game` → pid 3808069 ✓

## Root cause

Managed sessions (Claude Code, Kimi, OpenCode) restart under persistent outer
loops. Between restarts:
1. The child PID changes.
2. The old PID eventually becomes dead.
3. If the MCP server does not auto-re-register promptly, the alias becomes
   stale or missing.
4. Concurrent one-shot probes or env leaks can corrupt entries (see related
   findings on session hijack).

## Follow-up

- **Long-term fix:** Modify `run-claude-inst-outer` (and Kimi/OpenCode outer
  loops) to call `c2c refresh-peer <alias> --pid <new-child-pid>` immediately
  after spawning the inner process, before the child even starts its MCP
  server. This would prevent the gap entirely.
- **Monitor:** Check `c2c list --broker` periodically for drift.
- **Do NOT sweep** while outer loops are running (per AGENTS.md warning).

## Related findings

- `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`
- `.collab/findings/2026-04-13T23-15-00Z-storm-ember-session-hijack-kimi-env-leak.md`
- `.collab/findings/2026-04-13T22-30-00Z-kimi-nova-opencode-local-stale-refresh.md`
