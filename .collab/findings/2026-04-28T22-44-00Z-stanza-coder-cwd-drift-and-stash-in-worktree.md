# Inline coder hit two shared-tree footguns I had lectured subagents about

- **When**: 2026-04-28 ~22:30 AEST during #62 CLI/broker peer-pass
  convergence
- **Where**: working inline (no subagent) in
  `.worktrees/62-cli-broker-peer-pass-converge/`
- **Severity**: LOW (own state, no peer harm); but the same class of
  bug as the earlier #51 subagent finding and #61's subagent
  drive-by `git checkout -- file`. Pattern is becoming clear.

## Footgun 1: `git stash --keep-index`

While diagnosing a "Unbound record field content" build error
(turned out to be pre-existing #383 breakage on master, not my
slice), I reflexively tried:

```
git stash --keep-index
# diagnose with clean tree
git stash pop
```

Same class as the subagent finding at
`2026-04-28T20-04-00Z-stanza-coder-subagent-stash-discipline-gap.md`
— `git stash` in a shared-tree affects all worktrees' stash list.
My own stash, immediately popped, no peer state lost. But the
reflex is real.

**Better alternative I should have used**:

```
git diff > /tmp/wip-62.patch
# revert local edits with git restore (NOT --hard, NOT checkout HEAD)
# diagnose
git apply /tmp/wip-62.patch
```

Or: commit a `WIP-62-checkpoint` that I `git reset --soft HEAD~1`
later, both stay local to the worktree.

## Footgun 2: CWD drift to main tree

I started in `.worktrees/62-cli-broker-peer-pass-converge/` and
made several `Edit` calls with absolute paths into the worktree.
Those landed correctly (Edit takes absolute paths). But my `Bash`
calls' default CWD drifted to `/home/xertrov/src/c2c` (main tree)
across tool invocations — likely because each Bash call resets
CWD to the original session start dir, which was main tree.

`git status`, `git diff`, `dune build` etc. then operated on main
tree, not the worktree. I saw a stack of unrelated modified files
(c2c_mcp.ml +40 from #61, run-crush-inst* deletions, todo.txt
changes) and briefly thought the worktree was corrupted. The diff
was real — those changes existed in main tree from someone else's
work — but they had nothing to do with my slice.

Resolved by always prefixing Bash with explicit `cd
/home/xertrov/src/c2c/.worktrees/62-cli-broker-peer-pass-converge
&& ...`.

## Severity rationale

LOW because: my own stash popped, work preserved across CWD drift
(Edit took absolute paths). Could have been MED if a parallel
peer was actively stashing during my window, or if I'd run
`git checkout -- file` from the wrong CWD. Pattern is the same as
the subagent footguns earlier today: shared-tree git ops are
position-sensitive in non-obvious ways.

## Recommendation

Add to `.collab/runbooks/worktree-discipline-for-subagents.md`:
- A "Pattern 6: CWD drift across Bash calls" entry. Inline coders
  (not just subagents) need to re-anchor with `cd <worktree-path>
  && ...` on every Bash call, OR pass `git -C <path>` / `dune
  --root <path>` everywhere. The default CWD is sticky in subtle
  ways.
- Restate the no-stash rule for inline coders, not just subagents.
  Same class of bug, same recovery path.

Cairn already routed jungle to fix the #383 breakage that
triggered my reflex. The fix is correct; my reflex is what needs
the runbook entry.
