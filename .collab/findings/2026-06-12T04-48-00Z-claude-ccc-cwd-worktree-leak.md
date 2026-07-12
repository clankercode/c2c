# ccc/opencode agents edit the MAIN tree when launched with main-tree cwd

**UTC:** 2026-06-12T04:48Z · **alias:** claude (bake-off orchestrator) · **severity:** Sev1 (worktree-discipline violation, silently corrupts main tree)

## Symptom
Dispatched an opencode model (mm27) to implement P4 in worktree
`.worktrees/wt-p4-clients`, with a prompt explicitly naming the worktree path
and `--root <worktree>` for builds. The agent's file **Edits landed in the
MAIN tree** (`/home/xertrov/src/c2c/ocaml/...`), NOT the worktree. The P4
worktree stayed empty; the main tree accumulated 5 modified files with an
incomplete (syntax-error) WIP, which broke `dune build` on master and blocked
the cherry-pick merge pipeline.

## Discovery
After cherry-picking silent-send onto master, `dune build` failed with a syntax
error in `test_c2c_kimi_notifier.ml:580` — a file silent-send never touched.
`git status` in the main tree showed 5 uncommitted P4 files
(`c2c_kimi_notifier.ml/.mli`, `c2c_deliver_inbox.ml`, `c2c_deliver_watch.ml`,
`test_c2c_kimi_notifier.ml`). The running P4 agent's transcript showed
`Index: /home/xertrov/src/c2c/ocaml/...` (main tree), while a sibling agent
(mm3 #7 harness) correctly showed `Index: .../.worktrees/wt-hook-harness/...`.

## Root cause
I launched `cd /home/xertrov/src/c2c && ccc --yolo @mm27 "..."`. **opencode's
working directory = the ccc launch cwd = the MAIN tree.** opencode resolves
relative file paths (and its git project root) against its cwd, so when the
agent edited EXISTING files via repo-relative paths (`ocaml/c2c_deliver_watch.ml`),
they hit the main tree. The prompt text saying "work in the worktree" does not
change opencode's cwd. Agents that CREATE new files from absolute worktree
paths (mm3's `test_inbox_hook_harness.ml`) happened to land correctly, masking
the bug for impl-new-file slices; it bites slices that EDIT existing files.

## Fix
**Launch ccc with cwd = the slice worktree**, not the main tree:
```
cd /home/xertrov/src/c2c/.worktrees/<slice> && ccc --yolo @<model> "..."
```
And in the prompt, state "your cwd IS the worktree; edit paths relative to cwd;
do NOT touch the main tree." Re-dispatched P4 this way (task b756grfwa) — verified.

## Recovery performed
1. `git diff > /tmp/mm27-p4-partial-*.patch` (saved the WIP — never lose work).
2. `TaskStop` the misdirected run.
3. `git checkout -- <5 files>` to restore main tree to HEAD (coordinator).
4. `dune build -j2` → rc=0 (master clean again).
5. Re-dispatched P4 from inside the worktree.

## Prevention / follow-up
- All future ccc dispatches in this orchestration cd into the worktree first.
- Consider a `scripts/` wrapper that takes a worktree + model and cd's for you,
  refusing to launch from the main tree (mirrors the worktree-discipline shim).
- Cross-link: `.collab/runbooks/worktree-discipline-for-subagents.md` (this is a
  new variant of the "subagent crosses worktree boundary" family — the boundary
  is crossed by the LAUNCH cwd, not by the agent cd-ing).
