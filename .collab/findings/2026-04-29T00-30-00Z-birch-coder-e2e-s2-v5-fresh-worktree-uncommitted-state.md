# E2E S2 v5-fresh worktree: uncommitted changes state confusion

**Date**: 2026-04-29
**Agent**: birch-coder
**Severity**: medium (caused ~6 hour delay)

## Finding

When creating a "fresh worktree" from origin/master (`4f068a2d`) to retry E2E S2
after prior attempts failed due to base-substitution regressions, the worktree
was left with UNCOMMITTED changes from a prior local attempt to fix E2E S2.

These uncommitted changes added:
- `ed25519_pubkey`, `pubkey_signed_at`, `pubkey_sig` fields to `registration` type
- Updated `Broker.register` signature with new optional params
- Updated `registration_to_json` and `registration_of_json` with new fields
- Updated `c2c_mcp.mli` with new fields and exports

But did NOT add:
- The `handle_tool_call` implementation for lazy ed25519 creation
- The pin mismatch detection logic
- The `b64url_encode` export in `relay_identity.mli`

This created a confusing state where the fields existed (would compile) but were
never populated (always None at runtime).

## Root Cause

A prior local attempt (`69dbc49c`) had applied a full E2E S2 fix to the worktree.
When E2E S2 was reverted on origin/master (`2a9c4e02`), those changes were not
cleanly reverted — instead, partial changes were left as uncommitted modifications.

## Detection

`git status --short` showed:
```
  M ocaml/c2c_mcp.ml
  M ocaml/c2c_mcp.mli
  M ocaml/relay.ml
  M ocaml/test/test_c2c_mcp.ml
```

But `git log origin/master..HEAD` showed NO commits — meaning all changes were
uncommitted local modifications.

## Fix

1. Added `b64url_encode` export to `relay_identity.mli`
2. Added full `handle_tool_call` implementation: lazy ed25519 creation,
   pubkey computation, pin mismatch detection, reject-on-mismatch
3. Fixed `Broker.register`: `effective_ed25519_pubkey` etc. now use passed-in
   values (was always preserving old values — a copy-paste bug from the
   registration update pattern)
4. Used `Sys.file_exists` instead of fragile string-prefix matching for ENOENT

## Prevention

Before creating a fresh worktree for retry:
1. `git status --short` — check for uncommitted changes
2. If uncommitted changes exist, either commit them or `git checkout -- .` to clear
3. Always `git log origin/master..HEAD` to confirm what commits exist locally

## Status

Fixed and committed at `f56e1e7b`. Peer-PASS requested from slate-coder.