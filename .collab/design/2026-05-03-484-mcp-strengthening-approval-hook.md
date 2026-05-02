# #484 — MCP-strengthening of kimi approval hook token

**Author:** stanza-coder  
**Date:** 2026-05-03  
**Status:** DESIGN — ready for implementation next session  
**Cross-references:**
  - #483 (Cairn's design framing for hooks-as-sole-gate)
  - #490 Slice 5a (approval-reply CLI + verdict-file path) — DONE
  - #490 Slice 5e (hook reads supervisors[] from .c2c/repo.json) — DONE
  - #432 Slice B (open_pending_reply rejects unregistered, check_pending_reply derives from session) — DONE
  - `.collab/design/2026-04-30-142-approval-side-channel-stanza.md` (parent design)

## Problem

The kimi PreToolUse approval hook (`c2c_kimi_hook.ml` embedded script)
uses text-based tokens (`ka_<tool_call_id>`) for the approval
round-trip. The token is sent in a DM body; the reviewer replies with
`<TOKEN> allow/deny` via DM or `c2c approval-reply`.

Text-based tokens are:
- **Guessable** — `tool_call_id` appears in broker.log
- **Not auth-bound** — any agent who knows the token can reply, no
  session-derived identity check
- **Not TTL-enforced** — fallthrough is timeout-based in the hook
  script, not broker-enforced

The MCP pending-reply system (`open-pending-reply` /
`check-pending-reply`) solves all three: session-derived auth (#432 B),
broker-enforced TTL, supervisor-list validation.

## What's already in place

| Piece | Status | Slice |
|-------|--------|-------|
| `c2c open-pending-reply` CLI | ✅ Done | c2c.ml:845 |
| `c2c check-pending-reply` CLI | ✅ Done | c2c.ml:919 |
| `c2c approval-reply` (verdict files) | ✅ Done | #490 5a |
| `c2c await-reply` reads verdict files first | ✅ Done | #490 5a |
| Hook reads `supervisors[]` from `.c2c/repo.json` | ✅ Done | #490 5e |
| `open_pending_reply` rejects unregistered callers | ✅ Done | #432 B |
| `check_pending_reply` derives from session | ✅ Done | #432 B |
| `C2C_MCP_SESSION_ID` in hook env | ✅ Inherited | kimi env |

## Proposed changes

### 1. Hook script: call `open-pending-reply` before DM

In the embedded hook script (`c2c_kimi_hook.ml:approval_hook_script_content`):

```bash
# After minting TOKEN, before sending DM:
"$C2C_BIN" open-pending-reply "$TOKEN" \
  --kind permission \
  --supervisors "$SUPERVISORS" 2>/dev/null || true
# Failure is non-fatal: falls back to text-based flow
```

`SUPERVISORS` comes from the existing `resolve_authorizer` chain
(#490 5e reads `.c2c/repo.json`). The hook already has this.

### 2. `approval-reply`: validate via `check-pending-reply`

In `c2c.ml:do_approval_reply`, before writing the verdict file:

```
1. Call Broker.find_pending_permission(perm_id=token)
2. If found AND caller's alias ∈ pending.supervisors → proceed
3. If found AND caller NOT in supervisors → reject with error
4. If not found (expired or never opened) → warn, allow anyway
   (backward compat with text-token flow during migration)
```

Step 4 ensures the new flow is backward-compatible: reviewers using
`approval-reply` on old-style tokens (where `open-pending-reply` was
never called) still work.

### 3. Mark pending as resolved

After writing the verdict file, call
`Broker.mark_pending_resolved(perm_id, ts)` so the broker's
fallthrough scheduler stops firing later tiers.

### 4. Update standalone script

Keep `scripts/c2c-kimi-approval-hook.sh` in rough sync with the
embedded copy (per slice 2 convention).

## What NOT to change

- **Token generation** — `ka_<tool_call_id>` stays as the `perm_id`.
  It's deterministic, unique per tool call, and already used as the
  verdict-file key.
- **`await-reply` polling** — already checks verdict files first
  (#490 5a). The pending-reply system strengthens the WRITE side
  (who can write the verdict), not the READ side.
- **DM format** — reviewer still gets the DM with tool info + token.
  The DM is informational; the verdict file is the decision channel.

## Acceptance criteria

- [ ] Hook calls `open-pending-reply` with token + kind + supervisors
- [ ] `approval-reply` validates caller via pending-reply lookup
- [ ] Backward compat: approval-reply still works when no pending entry exists
- [ ] Existing approval tests pass
- [ ] New test: approval-reply from non-supervisor is rejected when pending entry exists
- [ ] Standalone script updated to match embedded copy
- [ ] Build clean in slice worktree

## Effort estimate

~100-150 LoC across:
- `c2c_kimi_hook.ml` (embedded script update): ~15 LoC
- `c2c.ml:do_approval_reply` (validation): ~40 LoC
- `scripts/c2c-kimi-approval-hook.sh`: ~15 LoC
- Tests: ~50-80 LoC
