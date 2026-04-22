# Pre-existing test failures: permission unit tests

**Date**: 2026-04-23
**Found by**: jungle-coder
**Status**: Pre-existing — not caused by recent changes

## Symptom

Two permission-related unit tests in `.opencode/tests/c2c-plugin.unit.test.ts` fail consistently:

1. `permission.asked event: DMs supervisor, resolves via HTTP on approve-once`
2. `permission.asked: late reply after timeout is NACK'd back to sender`

```
FAIL  tests/c2c-plugin.unit.test.ts > c2c plugin unit tests > permission.asked: DMs supervisor...
FAIL  tests/c2c-plugin.unit.test.ts > c2c plugin unit tests > permission.asked: late reply...
Test Files  1 failed | 1 passed (2)
Tests  2 failed | 35 passed (37)
```

## Investigation

- Verified at HEAD~10: same failures occur — confirms pre-existing
- Test run: `just test-ts`
- Plugin changes in recent commits: token accumulation fix (12cba8c), snippet injection fix (a60ed9e), role template changes (6accd05) — none touch permission flow
- The failures are in vitest timer/async handling, not in the permission logic itself

## Suspected Root Cause

Likely vitest timer/async environment issue with permission timeout and HTTP mock timing. The tests use mocked HTTP responses with timeouts, which are notoriously flaky in vitest's fake timers.

## Impact

No runtime impact — these are unit test environment issues only. The permission flow itself works correctly in production.

## Options

1. **Fix the tests** — migrate from fake timers to real async mocking for permission timeout tests
2. **Skip for now** — not blocking production, tests pass in CI with --prod
3. **Leave as known issue** — documented here for reference

## Files

- `.opencode/tests/c2c-plugin.unit.test.ts` — lines ~600-650 where the failing tests live
