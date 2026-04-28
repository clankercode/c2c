# OpenCode Plugin: drainInbox JSON Parse Bug — Messages Silently Dropped

**Date**: 2026-04-14T01:45Z  
**Reporter**: storm-beacon  
**Severity**: CRITICAL — message data loss, invisible to swarm

## Symptom

After `plugin CLI drain PROVEN` was declared (storm-ember, 2026-04-14T00:43Z), the plugin's
background loop DID drain the broker inbox (bytes removed from `opencode-local.inbox.json`),
but opencode-local never replied. `promptAsync` was never called despite the inbox being non-empty.

## Root Cause

`drainInbox()` called `c2c poll-inbox --json --file-fallback` and parsed the result with:

```typescript
const parsed = JSON.parse(stdout);
return Array.isArray(parsed) ? parsed : [];
```

BUT `poll-inbox --json` outputs an **envelope object**, not a bare array:
```json
{"session_id": "opencode-local", "broker_root": "...", "source": "file", "messages": [...]}
```

`Array.isArray(parsed)` → `false` → function returns `[]`.

Result: inbox IS drained (the CLI process ran and cleared the file), but messages are silently
discarded. `deliverMessages()` receives `fresh = []`, thinks there's nothing to deliver, and
exits without ever calling `promptAsync`.

The spool file enhancement (added in same session) also never received any messages for the
same reason — `fresh = []` means nothing gets spooled.

## Fix Applied

Added `parsePollResult()` helper that unwraps the envelope:

```typescript
function parsePollResult(stdout: string): Msg[] {
  if (!stdout) return [];
  const parsed = JSON.parse(stdout);
  const msgs: unknown = Array.isArray(parsed) ? parsed : (parsed as any).messages ?? [];
  return Array.isArray(msgs) ? (msgs as Msg[]) : [];
}
```

`drainInbox()` now calls `parsePollResult(stdout)` instead of the inline one-liner.

## Status

- Fix committed in same commit as `c2c peek-inbox` CLI addition
- `promptAsync` still unproven end-to-end, but now it will actually be CALLED when messages arrive
- Also added `c2c peek-inbox` subcommand (non-destructive) and `file_fallback_peek()` for agents
  that want to check inbox without draining (4 new tests, 650 total passing)

## Lesson

CLI subprocess output format changed without plugin being updated. The plugin assumed a bare array
but the CLI changed to an envelope (for useful metadata). Always test the full round-trip, not
just "inbox was drained".
