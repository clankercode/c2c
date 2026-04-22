---
title: Permission request DM never reached supervisor; stale PID drift + alias cruft
date: 2026-04-22T13:58:00Z
reporter: coordinator1
severity: High — breaks permission approval flow end-to-end
status: Mitigated (PID refreshed, alias cruft cleaned); root-cause investigation pending
---

# Symptom

Max observed jungle-coder's OpenCode session stuck on a "Access external directory ~/.claude/hooks" permission prompt. The plugin is supposed to DM the configured supervisor(s) (`coordinator1`, `planner1`, `ceo` per `.c2c/repo.json`, broadcast strategy) so one of them can approve via DM. coordinator1's inbox + archive showed no trace of the request.

# Discovery

- `mcp__c2c__poll_inbox` returned nothing from jungle for the permission request.
- `.git/c2c/mcp/archive/coordinator1.jsonl` had no entry.
- `.git/c2c/mcp/dead-letter.jsonl` last touched at 23:48 UTC (before the prompt appeared) — so the DM was never even enqueued to dead-letter.
- `.git/c2c/mcp/broker.log` had 0 hits on "permission" or "supervisor" strings.

# Contributing factors

1. **Stale PID drift.** `mcp__c2c__list` showed `jungle-coder` registration with `pid=424242, alive=false`. Live OC session is actually PID 469905 (verified via `/home/xertrov/.local/share/c2c/instances/jungle-coder/inner.pid`). PID 424242 does not exist. Broker's liveness-by-PID check marks the registration dead, which may cause send-paths to bail.

2. **Alias cruft.** Two overlapping registrations exist:
   - `session_id=6e45bbe8-...` alias `jungle-coder` pid 424242 alive=false (stale, correct alias)
   - `session_id=jungle-coder` alias `jungel-coder` alive=null (earlier typo, abandoned)
   The typo (`jungel-coder`) is NOT an active bug — nothing uses it — but it pollutes `c2c list` output. Plugin state file confirms the live alias is `jungle-coder` (correct spelling).

3. **"External directory access" prompt may not emit `permission.asked`.** OC's plugin listens to the `permission.asked` SDK event (c2c.ts:882). Directory-access prompts may be a different permission class that bypasses this event. Untested.

# Mitigation applied

- `c2c refresh-peer jungle-coder --pid 469905` — updated the stale registration to the real PID. jungle's outbound DMs should now work.
- User manually unblocked jungle via tmux (`c2c_tmux.py keys jungle-coder Enter`) — "Allow always" confirmed.

# Update 2026-04-23T14:10 UTC (galaxy-coder)

- Item 4 (one-shot cleanup) DONE: `jungel-coder` typo entry removed from registry. Entry had 0 inbox messages, safe to drop. Stale `jungle-coder pid=424242` entry was already gone (refreshed via `c2c refresh-peer`).
- Status updated: PID refreshed, alias cruft cleaned up. Remaining: items 1-3 above.

# Remaining investigation

1. Does OC's "external directory access" prompt actually emit `permission.asked` at all? Add a log statement in c2c.ts:882 handler and force-trigger an external-dir prompt to verify.
2. If the event IS emitted, why did the plugin fail to send? Check sender-registration validation in the send path (does it require self-alive?).
3. Sweep-policy: should sweep (or a lighter reconcile) detect "alias exists live in instances/ but registry shows dead PID" and auto-refresh? That would prevent recurrence.

# Severity justification

Permission prompts stall OC peers entirely. If the supervisor can't be reached, the only recovery is manual tmux intervention. This makes the swarm fragile to any PID drift in managed OC instances.
