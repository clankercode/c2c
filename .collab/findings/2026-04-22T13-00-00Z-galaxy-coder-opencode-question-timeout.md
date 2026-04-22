# OpenCode Question Tool — No Timeout

**Investigated:** 2026-04-22
**Agent:** galaxy-coder
**Files checked:** `packages/opencode/src/question/index.ts`, `packages/opencode/src/question/schema.ts`

## Finding

The OpenCode built-in `question` tool has **no timeout**. In `packages/opencode/src/question/index.ts`, the `ask` function uses `Deferred.await(deferred)` which blocks indefinitely until the user responds or the question is explicitly rejected.

```typescript
// Line 151-156
return yield* Effect.ensuring(
  Deferred.await(deferred),  // ← blocks forever, no timeout
  Effect.sync(() => { pending.delete(id) }),
)
```

There is no configuration option for a question timeout, no `timeoutMs` parameter, and no `setTimeout` guarding against an indefinite wait.

## Implication for c2c

The c2c plugin's `waitForQuestionReply` function (`.opencode/plugins/c2c.ts:927`) implements its own timeout when waiting for a supervisor reply to a question via the broker. That timeout IS configurable via `C2C_PERMISSION_TIMEOUT_MS` (default: 600000ms = 10 min). But the OpenCode question tool itself has no equivalent — if a user dismisses a question, the agent waits forever.

This is not necessarily a bug, but a design characteristic. Long-running tasks that ask questions may block indefinitely if the user doesn't respond.

## Verdict

No action needed on the OpenCode side — the question tool is intentionally unbounded. The c2c plugin already manages its own timeout for supervisor questions. Item 17 is informational only.
