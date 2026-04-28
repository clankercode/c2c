# Finding: #295 — OpenCode first-message delivery race

**Date**: 2026-04-26
**Agent**: galaxy-coder
**Status**: investigation in progress

## Symptom

First message to an OpenCode peer is *sometimes* not delivered. Subsequent
messages arrive normally.

## Delivery path (working case)

```
Sender → broker → <alias>.inbox.json
                         ↓
              c2c monitor (inotifywait on broker dir)
                         ↓ 📬 event
                    tick() → tryDeliver()
                                        ↓
                              deliverMessages(sid)
                                        ↓
                              drainInbox()
                                        ↓ runC2c(["oc-plugin", "drain-inbox-to-spool", ...])
                                        ↓ OCaml: lock + read inbox + write spool + clear inbox
                                        ↓
                              readSpool()
                                        ↓
                              promptAsync(sessionId, envelope)
                                        ↓
                              OpenCode session receives message
```

## Root cause hypothesis (probable race)

### Race window: message arrives before `session.created` fires

When the plugin loads, `activeSessionId` is initialized from
`C2C_OPENCODE_SESSION_ID` (e.g., the instance name `"galaxy-coder"`), **not**
the real OpenCode session ID (`"ses_xxxx"`).

If a message arrives at the broker **before** `session.created` fires:

1. Broker writes to `<real-sid>.inbox.json`
2. Monitor catches inotify event → tick()
3. `tryDeliver()` sees `activeSessionId = "galaxy-coder"` (instance name)
4. `deliverMessages("galaxy-coder")` is called
5. `drainInbox()` → OCaml resolves `"galaxy-corer"` via
   `resolve_session_id_for_inbox` → correctly finds real session ID → reads
   correct inbox → **OK**
6. BUT: `promptAsync("galaxy-coder", ...)` is called with the **instance name**
   instead of the real session ID → OpenCode API may reject or silently ignore

Meanwhile, `session.created` fires and sets `activeSessionId = "ses_xxxx"`.
The next periodic tick fires (5s) and delivers correctly.

**Fix**: `deliverMessages` must always use the **real OpenCode session ID**
(`activeSessionId` set by `session.created` or `bootstrapRootSession`), never
the raw `sessionId` (instance alias).

### Second race: `bootstrapRootSession()` is fire-and-forget

At line 1618: `void bootstrapRootSession();` — not awaited. If a message
arrives before `bootstrapRootSession()` resolves `activeSessionId` to the real
session ID, the same wrong-session-ID delivery occurs.

### Third race: periodic tick fires before `session.created` (no activeSessionId)

The first tick fires at t=1s. If `session.created` has not yet fired (possible
if plugin loaded during OpenCode startup before session creation completes),
`activeSessionId` is still `null` and `tryDeliver()` returns early:

```typescript
if (!sid) {
  // No session yet — waiting for session.created event.
  await log("tryDeliver: no session yet — waiting for session.created");
  ...
  return;
}
```

The message stays in the broker inbox until the **next** periodic tick at t=5s
(or `session.idle` fires). If `session.idle` never fires (continuous agent
activity), delivery depends on the 5s tick.

## Why subsequent messages work

After `session.created` fires, `activeSessionId` is set to the real session ID.
All subsequent deliveries use the correct ID. The first message may have been
delivered to the wrong session or silently dropped.

## Fix committed to worktree (rev 5 — `realConfiguredOpenCodeSessionId` helper, full adoption surface)

**Worktree**: `.worktrees/fix/295-plugin-sync/`
**SHA**: `2cb19712`

**Revs 1-4** were progressively more complete but missed the `pluginState` init
and `bootstrapRootSession`'s own early-return guard.

**Rev 5**: Added one line to `pluginState` init, plus 2 regression unit tests.

**Full change set**:

```typescript
// New helper
const realConfiguredOpenCodeSessionId: string =
  configuredOpenCodeSessionId.startsWith("ses") ? configuredOpenCodeSessionId : "";

// pluginState init — was using raw configuredOpenCodeSessionId
root_opencode_session_id: realConfiguredOpenCodeSessionId || null,

// activeSessionId init
let activeSessionId: string | null = (realConfiguredOpenCodeSessionId || null);

// All 7 hard-filter sites now use the helper
// bootstrapRootSession, shouldAdoptRootFromIdle, applyRootSessionCreated,
// applyPermissionState, session.status, session.compacted, session.idle

// Delivery guard (rev 2) — still in place
if (activeSessionId === sessionId) { drainToSpool(); return; }
```

**Regression tests** (2 new, both passing):
1. Alias-valued `C2C_OPENCODE_SESSION_ID` + `session.list` returns `ses_*`: bootstrap adopts
2. Alias-valued `C2C_OPENCODE_SESSION_ID` + `sessionCreated(ses_*)`: adopts real session

**Canonical source**: `data/opencode-plugin/c2c.ts` (git-tracked)
**Live deployed**: `~/.config/opencode/plugins/c2c.ts` (gitignored, kept in sync)
**Tests**: 41 passed in main session
**Status**: SHIPPED — cherry-picked `2cb19712` to origin/master by coordinator1

## Key code references

- `c2c.ts` line 315: `activeSessionId` initialization
- `c2c.ts` line 1541: `startBackgroundLoop()` — first tick at t=1s
- `c2c.ts` line 1521: `tryDeliver()` — early return if no sid
- `c2c.ts` line 1679: `session.created` sets `activeSessionId = info.id`
- `c2c.ts` line 1618: `void bootstrapRootSession()` — not awaited
- `c2c.ts` line 1452: `promptAsync(callArgs)` — delivery call
- `c2c.ml` line 131: `resolve_session_id_for_inbox` — alias→session resolution

## Verification

1. Live smoke test: send a test message to an OpenCode peer immediately after startup
2. Check `.opencode/c2c-debug.log` for delivery with real `ses_*` session ID
3. Check spool is cleared after successful delivery
