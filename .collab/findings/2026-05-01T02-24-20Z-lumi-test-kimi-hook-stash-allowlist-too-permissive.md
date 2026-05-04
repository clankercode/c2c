# Kimi Approval Hook: `git stash` Allowlist Too Permissive — Destructive Commands Bypass Approval

**Severity:** CRITICAL  
**Discovered during:** allowlist dogfood battery (#581 S2 follow-up)  
**File:** `/home/xertrov/.local/bin/c2c-kimi-approval-hook.sh` / `ocaml/cli/c2c_kimi_hook.ml`  
**Related commit:** `7b3e29d1` (changed `stash list` → `stash` in git subcommand allowlist)

## Summary

Commit `7b3e29d1` changed the bash `case` pattern from `stash list` to `stash` to fix a syntax error (unquoted multi-word pattern). However, this change makes **ALL** `git stash` subcommands bypass the approval hook, including destructive ones like `pop`, `push`, `drop`, `clear`, and `apply`.

## Live Impact

During dogfood testing, `git stash pop` executed without approval and caused a merge conflict in:
- `ocaml/cli/c2c_deliver_inbox.ml`
- `ocaml/cli/dune`

Both files are active #482 territory (birch's multi-week port). The agent had to manually clean up with `git checkout --ours` + `git add` to restore the working tree.

## Root Cause

The hook extracts only the first subcommand token (`$sub = awk '{print $2}'`). For `git stash pop`, `$sub` is `stash`. The allowlist matches `stash`, so the entire command is approved without checking the third token (`pop`).

## Code Context

```bash
      case "$sub" in
        status|log|diff|show|branch|tag|remote|config|rev-parse|\
        rev-list|describe|blame|reflog|ls-files|ls-tree|stash|fetch|\
        shortlog|count|status|-h|--help)
          return 0
          ;;
```

## Correct Fix

Option A (safest): **Remove `stash` entirely** from the allowlist. `git stash` commands require explicit approval. This is the conservative choice.

Option B: Parse `$sub2` (third token) for `stash` and only allow `stash list`. This adds complexity but preserves the convenience. However, `git stash` with no args also defaults to `push` — the hook would need to distinguish `git stash list` from `git stash` (no subcommand).

**Recommendation:** Option A. Stash operations are inherently stateful and risky. An agent requesting `git stash pop` should always get reviewer eyes.

## Cleanup Status

Working tree restored to clean state after the unauthorized `git stash pop`.
