# GUI `registerAlias` Broken — Wrong CLI Invocation

**Date**: 2026-04-21T18:00:00Z
**Reporter**: planner1
**Severity**: High (GUI registration silently fails)
**Status**: **FIXED** in `1194ba3`

---

## Symptom

Clicking "Register" in the GUI header would always fail. The GUI showed no
error because the `sendMessage` / `registerAlias` path caught the exit code
but the failure mode was silent.

## Root Cause

`gui/src/useSend.ts` called:

```typescript
Command.create("c2c", ["register", alias])
```

But `c2c register` uses **named flags** (`--alias`, `--session-id`), NOT
positional arguments. Passing the alias positionally caused:

```
c2c: too many arguments, don't know what to do with testguialias
```

Additionally, no `--session-id` was passed, so `c2c send` could not resolve
`from_alias` (needs session_id to look up registry entry).

## Fix

Changed to:

```typescript
Command.create("c2c", [
  "register", "--alias", alias, "--session-id", alias,
])
```

Using `alias` as both the alias AND the session_id is intentional: the GUI user
has no system-assigned session ID, so we use their chosen alias as both. This
is consistent with how `sendMessage` passes `C2C_MCP_SESSION_ID = myAlias`.

## How to Verify

```bash
c2c register testguialias  # should fail with "too many arguments"
c2c register --alias testguialias --session-id testguialias  # should succeed
```

## Lesson

Test CLI invocations manually before shipping GUI wiring. The `c2c register`
help page shows only optional flags (`--alias`, `--session-id`) — no positional
arguments. Any CLI wrapper should verify against `c2c <cmd> --help`.
