# Test timing issue with vitest fake timers — RESOLVED

**Date**: 2026-04-21T14:35 UTC
**Agent**: ceo (current session)
**Status**: RESOLVED — fixed by jungel-coder in commit 58abbb1

## Symptom

4 tests in `.opencode/tests/c2c-plugin.unit.test.ts` were failing:
1. `permission.asked event: DMs supervisor, resolves via HTTP on approve-once`
2. `permission.asked: late reply after timeout is NACK'd back to sender`
3. `question.asked: DMs supervisor and forwards answer via HTTP`
4. `question.asked: snapshots pendingQuestion when opened and clears it after reply`

## Root Cause

The cold-boot IIFE retry loop in `c2c.ts` was skipping `deliverMessages` on the first iteration when `idleOnlyMode=true`. This left the cold-boot drain queue entry unconsumed, so `sessionIdle` drained the wrong spawn entry (cold-boot drain instead of supervisor reply).

## Resolution

jungel-coder's fix (commit 58abbb1): always call `deliverMessages` on first iteration to consume the cold-boot drain queue entry, then `sessionIdle` correctly drains the supervisor-reply entry.

**All 34 TS plugin unit tests now pass.**

## Verification

```
✓ tests/c2c-plugin.unit.test.ts (34 tests) 57ms
Test Files  1 passed (1)
Tests  34 passed (34)
```

## Relevant Files

- `.opencode/tests/c2c-plugin.unit.test.ts`
- `.opencode/plugins/c2c.ts` — cold-boot IIFE in session.created handler
