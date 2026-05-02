# Peer-PASS: #627 Docker liveness fix (04e6625d)

**reviewer**: test-agent
**commit**: 04e6625da075854041218178a1f34c14a34e7e19
**author**: galaxy-coder
**review scope**: 1 file, 1 commit, +7 lines
**branch**: slice/627-docker-liveness

## Verdict: PASS

## Summary
Tiny, targeted fix. When a new registration evicts an old one with the same alias, the old inbox is deleted but the lease file was not. In Docker mode, `registration_is_alive` checks lease mtime — a stale lease with recent mtime makes the old session appear alive, blocking dead-letter and causing misdelivery.

---

## Diff Review

**Change**: `Unix.unlink (lease_file_path t ~session_id:reg.session_id)` added to the iter block that also deletes the inbox, with the same `try/with Unix.Unix_error _ -> ()` error guard.

**Correctness checks**:
1. `lease_file_path` is the same helper used elsewhere in the codebase for deriving a session's lease path — correct function
2. Same `try/with Unix.Unix_error _ -> ()` pattern as inbox deletion — error handling is consistent
3. In same `List.iter` block as inbox deletion — both cleanups happen in the same iteration over migrated registrations
4. Session ID is `reg.session_id` — the evicted registration's session, correct

**Bug mechanism addressed**:
- `registration_is_alive` in Docker mode checks lease mtime
- Without this fix, stale lease file with recent mtime → `registration_is_alive` returns `true` for dead session
- Dead session not dead-lettered → messages misdelivered to phantom session
- Fix deletes lease alongside inbox → evicted session's lease gone → `registration_is_alive` correctly returns `false` → dead-letter fires correctly

---

## Build / Tests
Build clean (rc=0, galaxy confirmed), 32 tests pass.
