# galaxy-coder: GUI loadPeerHistory session ID bug

**Date**: 2026-04-22
**Commit**: 5db6ae8
**Severity**: Medium (functional bug - peer history would not load correctly)

## Symptom

The peer DM history view in the GUI would not show any messages because `loadPeerHistory` was passing an alias string to the `--session-id` flag instead of the actual session ID.

## Root Cause

In `useHistory.ts`, the `loadPeerHistory` function had signature:
```typescript
loadPeerHistory(peerAlias: string, myAlias: string, limit = 50)
```

The second parameter was named `myAlias` but was being passed to `--session-id`:
```typescript
if (myAlias) args.push("--session-id", myAlias);
```

`--session-id` expects a session ID (e.g., `gui-abc-123-def`) not an alias (e.g., `galaxy-coder`). The `c2c history` command would look up the archive for a session with ID "galaxy-coder" which doesn't exist, returning no messages.

## Fix

1. Changed function signature to accept both `mySessionId` and `myAlias`:
   ```typescript
   loadPeerHistory(peerAlias: string, mySessionId: string, myAlias: string, limit = 50)
   ```

2. Pass `mySessionId` to `--session-id` flag

3. Updated call site in `App.tsx` to pass `mySessionIdRef.current` for session ID and `myAlias` for the alias filter

## Verification

Build passes cleanly.
