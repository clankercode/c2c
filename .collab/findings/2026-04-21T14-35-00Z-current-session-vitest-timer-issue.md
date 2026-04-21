# Test timing issue with vitest fake timers

**Date**: 2026-04-21T14-35-00Z  
**Agent**: (current session)  
**Severity**: non-critical (tests were pre-existing failures)

## Symptom

4 tests in `.opencode/tests/c2c-plugin.unit.test.ts` fail consistently:

1. `permission.asked event: DMs supervisor, resolves via HTTP on approve-once`
2. `permission.asked: late reply after timeout is NACK'd back to sender`
3. `question.asked: DMs supervisor and forwards answer via HTTP`
4. `question.asked: snapshots pendingQuestion when opened and clears it after reply`

All 4 involve the permission/question flow that sends DMs to a supervisor via `runC2c(["send", ...])`, which calls `drainInbox`.

## Root Cause

`createFakeProc` uses `setImmediate` to emit stdout data and close event:

```typescript
setImmediate(() => {
  if (out.stdout) proc.stdout.emit('data', Buffer.from(out.stdout));
  if (out.stderr) proc.stderr.emit('data', Buffer.from(out.stderr));
  proc.emit('close', out.code);
});
```

Tests use `vi.useFakeTimers({ toFake: ['setTimeout', 'setInterval'] })` in `beforeEach`.

**Problem**: Even though vitest is configured to only fake `setTimeout`/`setInterval`, the `setImmediate` callbacks from `createFakeProc` do NOT fire when `vi.advanceTimersByTimeAsync(1)` or `vi.advanceTimersByTimeAsync(250)` is called. This is vitest 3's behavior.

**Why `vi.advanceTimersByTimeAsync(250)` sometimes works**: It advances fake time by 250ms. If there are pending fake `setTimeout`s (like the permission timeout), advancing past them fires them. But `setImmediate` is NOT a fake timer — it fires in the macrotask queue. The 250ms advance apparently flushes the macrotask queue as a side effect in some vitest versions/configurations, but not consistently.

**Why the tests pass sometimes in isolation**: Test execution order affects the vitest timer state. Some test orderings leave the fake timer queue in a state where `advanceTimersByTimeAsync` happens to flush `setImmediate` callbacks.

## Attempted Fixes (all failed)

1. **`vi.advanceTimersByTimeAsync(250)` instead of `1`**: Doesn't flush `setImmediate`
2. **`vi.runAllTimersAsync()`**: Fires the permission timeout (10s) prematurely
3. **`vi.runAllTicks()`**: Doesn't flush `setImmediate`
4. **`setTimeout(0)` instead of `setImmediate`**: Changes relative ordering of spawn calls, breaks 10 other tests
5. **`queueMicrotask` instead of `setImmediate`**: Breaks 13 tests due to ordering change
6. **Sync emit in `createFakeProc`**: Breaks 13 tests (spawn call ordering changes)
7. **`vi.useFakeTimers()` (fake all timers)**: Causes test timeouts
8. **Temporary `vi.useRealTimers()` + `vi.useFakeTimers()`**: Complex, timeout tests would need refactoring

## Why Sync Emit Breaks Tests

When `createFakeProc` emits synchronously, the stdout `data` event fires before `spawn()` returns. This changes the relative ordering of when `proc.stdout.on('data', ...)` handlers are attached vs when data is emitted. Some tests assert on exact `spawnCalls` order/count, and this ordering change breaks those assertions.

## Key Insight

The 4 failing tests and the 10+ tests that break with sync emit are testing DIFFERENT spawn patterns. The failing tests use `queueSpawn` (which calls `createFakeProc`) for inbox drain operations. The broken tests use `spawnQueue.push` for liveness queries. These are different spawn use cases with different timing requirements.

## Options

1. **Accept the 4 pre-existing failures** — they were failing before this session started
2. **Refactor the 4 tests** to not rely on the `createFakeProc` mock for inbox drain — use a direct mock of `runC2c` instead
3. **Change `createFakeProc` to use a different timing mechanism** that vitest can control

## Relevant Files

- `.opencode/tests/c2c-plugin.unit.test.ts` — tests, line 41 (`setImmediate`)
- `.opencode/vitest.config.ts` — vitest 3.0.0 configuration
- `.opencode/plugins/c2c.ts` — `runC2c` and `drainInbox` functions
