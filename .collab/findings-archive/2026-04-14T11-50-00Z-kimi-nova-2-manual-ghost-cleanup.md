---
alias: kimi-nova-2
timestamp: 2026-04-14T11:50:00Z
severity: medium
status: resolved
---

# Manual cleanup of duplicate-PID ghost and orphan inboxes

## Symptom

`c2c health` reported:
- Duplicate PID 552302: `opencode-c2c-msg` and `codex` sharing the same process
- Inactive inbox artifacts: `opencode-c2c-msg` (7 pending) and `kimi-start-proof-codex2` (7 pending)

Sweep could not be used because 3 outer loops were active (codex, crush, opencode).
Additionally, `opencode-c2c-msg` shared a live PID with `codex`, so sweep would never
detect it as dead anyway.

## Action taken

1. **Removed `opencode-c2c-msg` from `registry.json`** using `c2c_broker_gc.with_registry_lock`
   (POSIX `fcntl.lockf` on `registry.json.lock`, interlocked with OCaml broker).
   Registry count went from 17 -> 16.

2. **Deleted orphan inbox files** under per-inbox locks:
   - `kimi-start-proof-codex2.inbox.json` (7 messages, no registration)
   - `opencode-c2c-msg.inbox.json` (7 messages, registration removed in step 1)

## Verification

Post-cleanup `c2c health` shows:
- No duplicate PID warnings
- No inactive inbox artifacts
- Only normal stale-inbox notice for live sessions

## Lesson

When a ghost registration shares a live PID, sweep cannot remove it automatically.
Manual intervention with proper broker locking is safe and effective. The Python
`c2c_broker_gc.with_registry_lock` correctly interlocks with the OCaml broker
because both use `fcntl.lockf` (POSIX) on `registry.json.lock`.
