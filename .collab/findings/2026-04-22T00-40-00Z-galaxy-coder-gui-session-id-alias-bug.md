# GUI session_id vs alias bug in c2c history/poll-inbox

**Found:** 2026-04-22
**Agent:** galaxy-coder (current-session)
**Status:** FIXED (commit 744a5d4)

## Summary

The c2c GUI was passing `myAlias` (e.g. `"galaxy-coder"`) as `--session-id` argument to
`c2c history` and `c2c poll-inbox` CLI commands. The CLI expects a session ID (UUID or
`ses_*` string), not an alias. When `--session-id` is provided explicitly, the CLI uses
it directly WITHOUT alias resolution. This caused both commands to silently return empty
results, making the GUI's history and inbox features non-functional.

## Root Cause

The GUI stored only an `alias` (e.g. `"galaxy-coder"`) in localStorage, and used this
alias as if it were a session ID:

```typescript
// useHistory.ts - BEFORE (broken)
export async function loadHistory(limit = 100, sessionId?: string) {
  const args = ["history", "--json", "--limit", String(limit)];
  if (sessionId) args.push("--session-id", sessionId);  // passes alias as session_id!
  const result = await Command.create("c2c", args).execute();
  ...
}
```

The CLI's `history` command (c2c.ml:674):
```ocaml
let session_id = match session_id_opt with
  | Some sid -> sid  (* used directly, no alias resolution *)
  | None -> resolve_session_id_for_inbox broker  (* only falls back when arg absent *)
```

Since `resolve_alias_for_inbox` was never invoked (explicit arg was provided), the alias
was never resolved to a session ID. The archive lookup used the alias string as a literal
session ID, which didn't match any real session's archive file.

## The Fix

1. **Generate a GUI-specific session ID** on registration: `gui-<random36chars>`
2. **Store session_id** in localStorage alongside alias (`c2c-gui-my-session-id`)
3. **Pass the real session_id** to CLI commands that need it:
   - `c2c history --session-id <session_id>`
   - `c2c poll-inbox --session-id <session_id>`
   - `c2c register --session-id <session_id>`

The CLI correctly handles this since it uses the argument directly when provided.

## Files Changed

- `gui/src/App.tsx` - Added SESSION_ID_KEY, generateSessionId(), pass session_id to history/send
- `gui/src/useHistory.ts` - sessionId now passed as --session-id (was passing alias)
- `gui/src/useSend.ts` - registerAlias takes (alias, sessionId)
- `gui/src/components/WelcomeWizard.tsx` - generates sessionId internally, passes to onComplete
- `gui/src-tauri/tauri.conf.json` - CSP hardening

## Verification

- TypeScript: `npx tsc --noEmit` — clean
- Vite build: `npm run build` — succeeds
- Rust: `cargo check` — compiles

## Lesson Learned

CLI commands with `--session-id` flags use the value directly WITHOUT alias resolution
when the flag is explicitly provided. Only the fallback path (no flag) triggers
`resolve_session_id_for_inbox` which CAN resolve aliases. The GUI must always pass
the real session ID, never an alias.
