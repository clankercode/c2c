# Issue Closed Receipt: #432 pending-permissions audit — B, C, D fully landed

**Agent**: willow-coder
**Date**: 2026-04-29
**Status**: CLOSED — no further slices needed

## Scope

All items from `.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md`
Findings 2, 4, and 5 (Finding 1 was a duplicate; Finding 3 was non-actionable).

## Verification

Tested on `origin/master` at `d44e14ca` (worktree `.worktrees/432-slice-c-capacity-bounds/`).

### Finding 2 — Capacity Bounds (Slice C)
- ✅ `pending_per_alias_cap = 16`, `pending_global_cap = 1024` constants at `c2c_mcp.ml:878-879`
- ✅ `open_pending_permission` checks both caps, raises `Pending_capacity_exceeded`
- ✅ MCP handler catches exception, logs `[pending-cap] reject` to `broker.log`, returns `is_error: true`
- ✅ AC1: per-alias cap raises at exactly 17 → test 61 `[432 C]`
- ✅ AC2: global cap raises at 1025 → test 61 `[432 C]`
- ✅ AC3: expired entries excluded from count → test logic validates `get_active_pending_permissions` filtering
- ✅ AC4: `is_error: true` on cap → test 64 `[432 C]`
- ✅ AC5: broker.log reject line → test 64 `[432 C]`

### Finding 4 — Auth Binding (Slice B)
- ✅ B1: `open_pending_reply` rejects unregistered callers → test 58 `[432 B1]`
- ✅ B2: `check_pending_reply` derives `reply_from_alias` from calling session, not args → test 59 `[432 B2]`
- ✅ B2 unregistered caller rejection → test 60 `[432 B2]`
- ✅ Schema: `reply_from_alias` marked DEPRECATED in `c2c_mcp.mli`

### Finding 5 — Decision Audit Log (Slice D)
- ✅ `log_pending_open` writes to `broker.log` with hashed `perm_id`/`session_id`
- ✅ `log_pending_check` on all 4 outcome branches: valid / invalid_non_supervisor / unknown_perm / expired
- ✅ `short_hash : string -> string` using `Digestif.SHA256.to_hex` truncated to 16 chars
- ✅ test 219: `pending_open` log line after successful `open_pending_reply`
- ✅ test 220: `pending_check` log line for unknown perm_id

### Test Suite
```
just build  → rc=0
just check  → rc=0
dune exec test_c2c_mcp.exe → 281 tests, all OK
```

## Breadcrumb for #438

After B+C+D, the only remaining pending-permissions finding from the 2026-04-29 audit is **Finding 3 (TTL gaps)** and the broader **#438 CRIT-1+2 relay-crypto critical path**. No pending-permissions items remain open on the auth/capacity/audit axis.
