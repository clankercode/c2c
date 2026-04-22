# GUI Error Handling Audit — c2c CLI Integration

**Audited:** 2026-04-22
**Agent:** galaxy-coder
**Files checked:** `gui/src/useSend.ts`, `gui/src/useHistory.ts`, `gui/src/useDiscovery.ts`, `gui/src/App.tsx`, `gui/src/Sidebar.tsx`

## Issues Found

### 1. `Sidebar` — `handleLeave`/`handleJoin` passed dead `sessionId` arg ❌ FIXED (3be6f77)
`handleLeave` called `leaveRoom(rid, myAlias, mySessionId)` — third arg was unused
since `leaveRoom` CLI command only accepts `--alias`, not `--session-id`.
`handleJoin` same — `joinRoom(rid, myAlias, mySessionId)` had dead third arg.
Fix: Removed `_sessionId` params from `useSend.ts` entirely; removed `mySessionId`
prop from Sidebar and all call sites.

### 2. `loadPeerHistory` in App.tsx — `mySessionId` passed where `myAlias` expected ❌ FIXED (3be6f77)
App.tsx line ~401 called `loadPeerHistory(target, mySessionId, 100)` — second
arg is named `myAlias` in `useHistory.ts` and gets passed as `--session-id` to the
CLI. But `mySessionId` is a session ID (e.g. `gui-abc123`) while `--session-id`
in `loadPeerHistory`/`loadHistory` is used for alias resolution. The CLI was
getting an invalid session ID (the GUI's own session ID instead of an alias).
Fix: Changed to `loadPeerHistory(target, myAlias, 100)`.

### 3. `useHistory` — `loadHistory`, `loadRoomHistory`, `loadPeerHistory` JSON.parse throws ❌ FIXED (43b687d)
All three functions `JSON.parse(result.stdout)` inside try/catch. If stdout contains
CLI error text (not JSON), the parse throws and is caught, returning `[]` silently.
This means history failures are completely silent — user sees no events but doesn't know why.

**Fix:** Added `console.error` with descriptive prefix at each JSON.parse catch site so
errors are visible in browser dev tools. Doesn't change return value (still `[]` on failure)
but makes the failure observable.

**Severity:** Medium — silent failures are worse than explicit errors.

**Note:** `result.code !== 0` check happens before JSON.parse, so non-zero exit codes
return `[]` without attempting parse. But if the CLI outputs text on stdout even on error
(e.g., a panic trace), parse throws and returns `[]`.

### 4. `useDiscovery` — same JSON.parse silent failure pattern
`discoverPeers`, `fetchHealth`, `discoverRooms` all use `JSON.parse(result.stdout)` inside
try/catch, silently returning empty/null on parse failure.

**Severity:** Medium — same pattern as useHistory.

### 5. App.tsx `monitor` — stderr suppressed
```typescript
cmd.stderr.on("data", () => { /* suppress */ });
```
Any error output from the `c2c monitor` subprocess is discarded. Useful for debugging
but acceptable since monitor is a long-running background process.

**Severity:** Low — intentional for clean logs.

### 6. `useSend` — registration errors trigger try/catch but no surface to UI
`registerAlias` returns `{ok: false, error}` but the only place it's called with
proper error display is `applyAlias` (shows error inline). WelcomeWizard swallows errors
via `.catch(() => {})`.

**Severity:** Low — WelcomeWizard errors are shown via `setError` in handleRegister.

### 7. `ComposeBar` and `WelcomeWizard` — passed `sessionId` to functions that don't accept it ❌ FIXED (3be6f77)
`ComposeBar` called `sendMessage(to, text, isRoom, myAlias, mySessionId)` — fifth
arg was unused since `sendMessage` CLI uses `--from` alias, not `--session-id`.
`WelcomeWizard` called `joinRoom("swarm-lounge", a, sid)` — third arg unused.
Fix: Removed unused `sessionId` params from call sites and Props.

## What Works Correctly

- `pollInbox` — checks `result.code !== 0` before parse, returns `[]` on failure ✓
- `sendMessage` — checks exit code, returns `{ok: false, error}` ✓
- `leaveRoom`/`joinRoom` — checks exit code, returns `{ok: false, error}` ✓
- `registerAlias` — checks exit code, returns `{ok: false, error}` ✓

## Recommendations

1. **JSON.parse error surfacing** — Add a `ParseError` variant to return types so callers
   can distinguish "empty result" from "parse failure". Or log parse errors to console.error.
2. **Room join/leave** — these CLI commands don't support `--session-id`. Future work:
   propagate `C2C_MCP_SESSION_ID` via subprocess env (requires Tauri shell env support).
3. **Error boundary in React** — consider wrapping the GUI in an error boundary to catch
   any unexpected render errors from the event feed.

## SessionId vs Alias Summary

- `c2c history` / `poll-inbox` — accept `--session-id` directly (CLI uses it without alias resolution)
- `c2c room join/leave` — NO `--session-id` flag; alias is resolved via env/registry
- `c2c send` — `--from` takes alias directly (no sessionId needed)
- `c2c register` — accepts `--session-id` directly

The GUI correctly generates and stores a `gui-<random>` sessionId for registration,
history, and poll-inbox. Room join/leave use alias resolution which works correctly
when `--alias` is passed.
