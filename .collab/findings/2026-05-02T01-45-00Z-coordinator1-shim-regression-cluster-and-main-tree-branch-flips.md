# 🔴 Shim regression cluster + main-tree branch flips (cedar #611 v1+v2 + fern + cedar)

- **Filed**: 2026-05-02T01:45:00Z by coordinator1 (Cairn-Vigil)
- **Severity**: HIGH — operational disruption, two same-class footguns hit twice each in one hour
- **Status**: mitigated (clean shim restored both times); fix-forward in cedar's #611 v3 + peer-PASS rubric tightening (8d349be6 §5 already added)

## Summary

Two distinct footgun families both fired twice each during the 11:30–11:45
AEST (01:30–01:45 UTC) catastrophic-spike Phase-2 push:

1. **Shim-regression cluster**: cedar's #611 cache landed twice with shim
   syntax errors that broke EVERY `git` invocation under the
   `set -euo pipefail` strict-mode shim. v1 (6086858e) used backslash-
   escaped quotes inside `$()`; v2 used `local` outside a function. Both
   passed peer-PASS without runtime smoke-testing the actual generated
   shim.
2. **Main-tree branch contamination**: two peers' shells in this hour
   ran git ops in coord's main tree (`/home/xertrov/src/c2c`) instead of
   their `.worktrees/<slice>/` paths, switching the main tree's HEAD off
   master onto their slice branches. Pattern 6/13/14 violation, twice.

Both clusters share a root: **the rubric did not catch the proximal bug
because the verification was structural (build clean / commit format)
not behavioural (run the actual code path, in the actual location)**.

## Cluster 1: shim regressions (cedar #611 v1 + v2)

### v1 — backslash-escaped quotes inside `$()` (6086858e)

OCaml-generated bash literal inside the install code wrote:

```bash
MAIN_TREE="$(
    if [ -n \"${C2C_GIT_SHIM_MAIN_TREE:-}\" ]; then
        echo \"${C2C_GIT_SHIM_MAIN_TREE}\"
    ...
```

Inside a `$()` substitution, the backslash-escaped quotes become literal
`\"` characters; the shell parses `${...}` parameter expansion across
mismatched quotes and trips `set -u` strict mode on the unset
`C2C_GIT_SHIM_MAIN_TREE` variable. Symptom on every git call:
`unbound variable C2C_GIT_SHIM_MAIN_TREE`.

**Reverted as bcc67021** ~12 min after install.

### v2 — `local` outside a function

Cedar's v2 (re-applied via `c2c install`-style write to state path) had:

```bash
MAIN_TREE="$(
    if [ -n "${C2C_GIT_SHIM_MAIN_TREE:-}" ]; then
        echo "${C2C_GIT_SHIM_MAIN_TREE}"
    elif [ -d /tmp ] && [ -w /tmp ]; then
        local cache_file="/tmp/c2c-git-shim-main-tree-$$"   # ← not in a function
        local marker="MAIN_TREE_v1"
        ...
```

`local` is a function-scope keyword in bash. Outside a function it errors
`local: can only be used in a function`. Combined with `set -u`, the
subsequent `$cache_file` reference also fails as unbound. Symptom
identical from the user side: every `git` invocation fails with two
errors, exit 1.

Detected within 3 min of cedar's install (her `permission:approve-once`
DM landed at 11:43, my next cherry-pick attempt failed at 11:43 with
`local: can only be used in a function`). **Reverted by manually
copying repo `git-shim.sh` to `/home/xertrov/.local/state/c2c/bin/git-pre-reset`.**

### Why peer-PASS missed both

The shim is a **bash literal generated from OCaml string concatenation
or a static repo template**. The peer-PASS rubric checks:
- `dune build` clean ✓ (passes — the OCaml side compiles)
- `dune test` clean ✓ (passes — no test exercises the literal in a fresh shell)
- Author-runs-in-worktree ✓ (likely passes — but `set -euo pipefail`
  may not fire in the author's interactive shell where many quirks are
  silently tolerated)

What it does NOT check:
- `bash -n /path/to/installed/git-pre-reset` (parse-only check)
- `bash -c 'set -euo pipefail; PATH=<shim-dir>:$PATH git rev-parse HEAD'`
  in a fresh subshell

These are 2-second checks. They would have caught both regressions.

### Fix shape (DM'd cedar 01:43Z)

Cedar's v3 must:

1. Move ALL `local` declarations into a real function:
   ```bash
   compute_main_tree() {
       local cache_file marker tree
       ...
       echo "$tree"
   }
   MAIN_TREE="$(compute_main_tree)"
   ```
2. Drop backslash-escaped quotes inside `$()` — use plain `"` or
   here-doc the literal from a file.
3. Peer-PASS rubric for ANY shim-modifying slice (encoded into 9e1f9d33
   §5):
   - `bash -n <generated-shim-path>` (parse check)
   - Run `git rev-parse HEAD` through the new shim under `set -euo pipefail`
   - Both verdicts captured in the peer-PASS DM body.

## Cluster 2: main-tree branch flips (fern + cedar)

### Event A — fern at 11:38:44 AEST (01:38:44 UTC)

After fern's catastrophic-spike retrospective doc landed via cherry-pick
(8d349be6), the main tree's HEAD was `collab/findings/fern-catastrophic-
spike-retro` instead of `master`. My in-flight `git revert 6086858e`
landed on her branch as 991d45f8, NOT on master. Detected when next
`git status` showed unexpected branch.

**Mitigation**: `git cherry-pick --quit`, `git switch master`, redid
revert there (bcc67021).

### Event B — cedar at 11:40:15 AEST (01:40:15 UTC)

Cedar's `git rebase` on `slice/611-shim-cache-and-git-telemetry` ran in
coord's main tree, not her worktree. Rebase rewrote SHAs and the main
tree's HEAD was on her slice branch. Detected by reflex `git
rev-parse --show-toplevel` confirming I was on her branch instead of
master.

**Mitigation**: `git switch master`. DM'd cedar urgent.

### Common cause

Both peers had a shell session whose `pwd` was the main tree
(`/home/xertrov/src/c2c`) and not their `.worktrees/<slice>/` path.
git ops in that shell mutated the main tree's HEAD reference because
shared-tree layout means all worktrees share the same `.git/`. This is
**Pattern 6/13/14 — shared-tree destructive ops**.

The Pattern 6 doc warns about `git switch` and `git checkout`; the
broader corollary is that **any operation that mutates the working
tree's branch ref** does so from `pwd`, which is whichever directory
the shell was launched in. If the agent's shell was launched in the
main tree (e.g. coordinator's tmux pane), every git op the agent runs
hits the main tree.

### Why pre-reset shim doesn't catch this

The pre-reset shim refuses `git reset --hard` and `git commit` in the
main tree. It does NOT refuse:
- `git switch <branch>`
- `git checkout <branch>`
- `git rebase <upstream>` (when run on a non-master branch checked out
  in the main tree)
- `git cherry-pick <sha>` (only refused when it would orphan commits)

These are all branch-ref mutations. The shim's design point is "prevent
catastrophic data loss" not "enforce one-tree-per-slice". The latter is
a discipline gap, not a guard gap.

## Hardening proposals

### A. Shim-modifying-slice peer-PASS rubric (DONE)

Added to 9e1f9d33 §5 (fern's retrospective addendum). Reviewer must:
- `bash -n` the installed shim
- Run an actual git op through the shim under `set -euo pipefail` in a
  fresh subshell
- Capture both verdicts in the peer-PASS DM body

This is a **mandatory** prerequisite for any future shim-touching slice.
Backstop the rubric: if the peer-PASS DM doesn't include "shim-smoke:
bash -n PASS, fresh-subshell git PASS", reject the cherry-pick.

### B. Shell-launch-location guard (NEW PROPOSAL)

`c2c start <client>` should verify the agent's shell launched from the
agent's worktree, not the main tree. Mechanism: write the expected
worktree path into `.c2c/instances/<alias>/expected-cwd` at start; on
each `c2c send` or `c2c list` from that session, compare `pwd` against
the expected path; warn if mismatch.

This isn't a hard guard — agents may legitimately shell into other
worktrees for read-only ops — but a soft warn ("⚠️ your shell is in
main tree, your worktree is .worktrees/X — git ops will hit the wrong
ref") catches the contamination class early.

Filed as deferred slice candidate; do NOT pick up until #611 trio
fully shipped.

### C. Pre-reset shim coverage extension

Extend the pre-reset shim to refuse `git switch`, `git checkout
<branch>`, and `git rebase <upstream>` in the main tree for non-coord
agents. Same `C2C_COORDINATOR=1` bypass shape.

Caveat: this is a more aggressive guard and may produce false-refuses
for legitimate read-only-then-revert workflows (`git checkout origin/
master -- some-file` to grab a single file). Need careful scoping —
only block branch-ref-mutating forms.

Filed as #611-followup candidate.

## Cross-references

- `8d349be6` — fern's catastrophic-spike trio retrospective
- `9e1f9d33` — §5 heightened-review-for-shim-slices addendum
- `bcc67021` — revert of cedar #611 v1 (backslash-quote regression)
- `.collab/runbooks/worktree-discipline-for-subagents.md` Patterns 6/13/14
- `.collab/findings/2026-05-02T01-12-00Z-coordinator1-git-shim-self-exec-recursion-cpu-spike.md` — the spike that prompted the trio

## Action items

1. ✅ DM'd cedar fix shape for v3 (function-scoping `local`, parse +
   smoke check before PASS).
2. ✅ Shim-modifying-slice rubric encoded in 9e1f9d33 §5 (fern's PR).
3. (queued) Slice candidate: shell-launch-location guard (Hardening B).
4. (queued) Slice candidate: pre-reset shim coverage extension to
   `switch`/`checkout`/`rebase` (Hardening C).
5. ✅ Pattern 6/13/14 reinforcement: this finding documents the
   contamination chain explicitly so the next agent has a referent.

— Cairn-Vigil
