# Finding: #611 shim-cache regression — double shell-escaping + invalid `local` at top level

**Filed**: 2026-05-02T01:50:00Z
**Severity**: CRITICAL — every `git` invocation via shim path errors
**Status**: FIXED at `7659d99a`

## Symptom

Every `git` command via the installed `git-pre-reset` shim failed with:
```
line NNN: C2C_GIT_SHIM_MAIN_TREE: unbound variable
```
or:
```
local: can only be used in a function
cache_file: unbound variable
```

## Root Cause

Two distinct bugs in the #611 MAIN_TREE cache implementation in `git-shim.sh`:

### Bug 1: Backslash-escaped quotes (`\"`)

**Location**: `git-shim.sh` lines 28-49, inside `MAIN_TREE="$(...)"` block

The OCaml-generated (or directly-edited) shim had `\"` instead of `"` for all
double-quoted contexts inside the command substitution. With `set -euo pipefail`,
bash interprets `\$VAR` as literal backslash followed by expansion, breaking the
parameter-default operator `:-` and causing "unbound variable" errors.

**Fix**: Replace all `\"` with `"` — plain double quotes are correct inside a
bash command substitution.

### Bug 2: `local` declarations at top-level subshell

**Location**: same `MAIN_TREE="$(...)"` block

The subshell body used `local VAR=...` declarations directly at the top level
of the `$(...)` command substitution. `local` is only valid inside a function,
not at top-level of a subshell or script body. Bash errors with "local: can
only be used in a function".

**Fix**: Move all cache logic into a named `compute_main_tree()` function, then
call `MAIN_TREE="$(compute_main_tree)"`. `local` declarations are now inside
a proper function where they are valid.

## Timeline

1. #611 committed at `62d2dcdc` with the `MAIN_TREE` cache feature
2. `just bi` ran from main tree context (Pattern 6/13 violation) — installed worktree's buggy shim
3. Coordinator reverted #611 from master, restored clean version
4. Fix v1 (`91771566`): removed `\"` escapes — but missed the `local` bug
5. Fix v2 (`7659d99a`): moved cache logic into `compute_main_tree()` function

## Verification

```bash
# Reproducer (should output hash, not error):
env -u C2C_GIT_SHIM_MAIN_TREE bash -c \
  'set -euo pipefail; bash /home/xertrov/.local/state/c2c/bin/git-pre-reset rev-parse --short HEAD'

# Self-test (peer-PASS criterion for shim slices):
bash git-shim.sh --self-test
```

## Lessons

1. **Generated bash cannot use `local` at top-level subshell** — must be inside a function
2. **`\"` in bash strings is almost always wrong** — use plain `"` inside double-quoted contexts
3. **Test generated bash under `set -euo pipefail` with no env vars** — catches exactly these classes of bugs
4. **Shell session must stay in worktree** — running `just bi` from main tree instead of worktree is a Pattern 6 violation

## Related

- Pattern 6/13/14 violations in `.collab/runbooks/worktree-discipline-for-subagent.md`
- `#611` catastrophic spike mitigation
