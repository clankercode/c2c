# TUI focus bug: bootstrapRootSession cross-instance session contamination

**Date**: 2026-04-21  
**Severity**: HIGH — causes wrong session to be driven; TUI stuck on "New session" or showing another peer's session  
**Status**: FIXED — code change present in current master (lines 856-857 of `.opencode/plugins/c2c.ts`); original fix SHA `7b063ac3` was on a topic branch but the same change landed via a different path.

## Symptom

- `oc-focus-test` launched fresh, received a DM via c2c, replied correctly
- But TUI still showed "New session" banner and `root_opencode_session_id` in oc-plugin-state matched `oc-sitrep-demo`'s session ID
- `opencode-session.txt` not written (auto-kickoff was skipped)

## Root Cause

`ctx.client.session.list()` in the OpenCode server plugin returns **all sessions across all OpenCode instances** (shared `~/.local/share/opencode/` state). `bootstrapRootSession()` sorted by `time.updated` DESC and picked `roots[0]`, which was `oc-sitrep-demo`'s session (more recently active).

Once `activeSessionId` was set to sitrep-demo's session, auto-kickoff's guard at line 1085 (`if (activeSessionId) { skip }`) fired and `session.create()` was never called. The plugin happily delivered messages into the wrong session. The TUI remained on "New session" because `c2c-tui.ts` used the stale session ID, which OpenCode couldn't navigate to in the new instance.

## Fix (7b063ac)

`bootstrapRootSession()` now:
1. `configuredOpenCodeSessionId` set → **exact match only**, no `?? roots[0]` fallback  
2. `C2C_AUTO_KICKOFF=1` → **skip bootstrap entirely** (return `undefined`); let `session.create()` fire and set the ID from its return value  
3. Legacy (no kickoff, no configured ID) → `roots[0]` unchanged

## How to verify fix is working

After fix, launching `c2c start opencode -n oc-test-2`:
1. `bootstrapRootSession` returns without setting `root_opencode_session_id`
2. Auto-kickoff's `if (activeSessionId)` guard is false → `session.create()` fires
3. Plugin sets `activeSessionId` + `root_opencode_session_id` from create() return
4. `opencode-session.txt` written on `session.created` event (first root session)
5. TUI navigates to correct session via `c2c-tui.ts`
