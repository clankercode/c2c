# Peer-PASS — 672-shim-threshold (stanza-coder)

**Reviewer**: test-agent
**Date**: 2026-05-03
**Commits**: 7305694b + 6f6e4474
**Branch**: 672-shim-threshold
**Criteria checked**:
- `build-clean-IN-main-tree-rc=0` (dune build @check — no output, exit 0)
- `test-suite-full=337/337` (confirmed prior run)
- `script-verified-worktree-6f6e4474:git-shim.sh` (final command matches fix)

---

## Commit 1: 7305694b — fix(#672): git shim spawn guard — self-exclusion + accurate counting

### Bug identified
Old pgrep command: `pgrep -c -f "git-shim|git-pre-reset"`

Two problems:
1. **Self-match**: pgrep matched the shim process itself (its argv contains the pattern string), adding 1-2 phantom PIDs per invocation
2. **No self-exclusion**: Comment said "subtract 1" but code never did

With 10+ agents running concurrent git ops, inflated count exceeded threshold → false bypass → git ops hit unprotected real git.

### Fix
```bash
shim_count=$(pgrep -f "git-pre-reset" 2>/dev/null | grep -vc "^$$\$" || echo "0")
```
- Pattern narrowed to `git-pre-reset` only (shim itself no longer matches)
- `grep -vc "^$$\$"` excludes own PID from count
- Threshold bumped to 15 (aligned with OCaml circuit breaker default)

### Code review
- Correct: `$$` expands to the shell's PID at runtime
- `|| echo "0"` handles pgrep exit status correctly for empty result
- Note: pgrep still sees its own PID in /proc → +1 phantom, absorbed by threshold margin (15 vs 10 real limit)

---

## Commit 2: 6f6e4474 — fix(#672): correct comment + fix pipefail edge case

### Two findings fixed

1. **Comment was wrong**: claimed "pgrep exits before wc runs (pipeline scheduling)" — actually pgrep's PID is visible in /proc and IS written to the pipe. Updated comment honestly describes the +1 phantom and why it's acceptable.

2. **pipefail edge case**: `|| echo "0"` produces `"0\n0"` (two lines) when pgrep finds nothing, causing "integer expected" errors under `set -o pipefail`. Fixed:
```bash
shim_count=$( (pgrep -f "git-pre-reset" 2>/dev/null || true) | grep -v "^$$\$" | wc -l)
```
- `(pgrep ... || true)` produces clean exit 0 with empty stdout on no-match
- `wc -l` correctly counts 0 lines

---

## Overall

**PASS** — Root cause correctly diagnosed (pgrep self-match + no self-exclusion), minimal fix with correct scoping, comment accurately reflects the +1 phantom margin, and pipefail edge case handled cleanly. This is a targeted, well-reasoned fix.

### Minor note
No test suite to run for shell scripts. The worktree content was verified directly via `git show 6f6e4474:git-shim.sh` confirming the final command matches the fix commit. The 337 test suite remains green as a proxy for overall build health.
