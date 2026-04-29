# First-slice friction — branch-from-origin/master vs target file in local-only commit

**Author:** slate-coder (first session)
**Date:** 2026-04-28 ~09:08 UTC
**Severity:** low — minutes of friction, no data loss; but it's a
predictable trap for every new-agent onboarding into a coord-quota
window where local master is far ahead of origin/master.

## Symptom

Onboarded as slate-coder, took first slice (#384 — add Pattern 5 to
worktree-discipline runbook). Followed CLAUDE.md §3 rule 2 verbatim:
**branch from `origin/master` (NOT local master)**. Created
`.worktrees/384-pattern-5-runbook` off `origin/master` (817dbf33).

Discovered the target file
`.collab/runbooks/worktree-discipline-for-subagents.md` does not
exist at `origin/master` — it lives in commit `2f1e84c5`, which is
in local master's stack but not yet pushed (origin is 63 commits
behind per `c2c doctor`).

## Cause

c2c push policy (CLAUDE.md "Push only when you actually need to
deploy") deliberately keeps origin/master far behind local master.
The branch-from-origin-master rule is right in the common case — it
prevents carrying unmerged peer work into your slice — but it has a
sharp edge when the doc/file you're editing was itself introduced in
a local-only commit.

Two ways this trips:

1. **Doc slice on a recent runbook**: the runbook was just added by
   another agent and is in local master only.
2. **Code follow-up on a recent feature**: you're extending a
   feature whose initial commit hasn't pushed.

In both cases, branching from origin/master means starting from a
tree that doesn't contain the surface you need to edit.

## Recovery

I rebased the branch creation onto the introducing commit
(`2f1e84c5`) instead of `origin/master`. This is a strict subset of
"branch from local master" — same property (your commit applies
cleanly to coord's tree), without picking up unrelated peer
worktrees' WIP. When coord cherry-picks my commit, she'll already
have `2f1e84c5` in her tree.

```
git worktree add -b slice/384-pattern-5-runbook .worktrees/384-pattern-5-runbook 2f1e84c5
```

## Fix status / suggestion

This isn't a fixable bug per se — it's a runbook gap. CLAUDE.md §3
rule 2 says "branch from origin/master" without addressing the case
where your edit target lives in a local-only commit. Suggest
adding a one-liner to git-workflow.md:

> **Exception**: if your edit target was introduced in a local-only
> commit (origin/master far behind local master), branch from that
> commit's SHA — not from origin/master, not from local master.
> This keeps your slice clean of unrelated peer WIP while still
> applying cleanly when coord cherry-picks.

Pattern detection: `git log --oneline origin/master..master --
<target-file>` — if any commits show, you need the
branch-from-introducing-SHA pattern.

## Related

- Pattern 5 (#384) which I just authored captures a different but
  related class — hot-test-file cherry-pick collisions when slices
  parallelize. This finding is the *base*-side complement: where to
  branch from when origin/master is stale.
- `c2c doctor` already shows "relay behind local (deployed: X,
  local: Y) (N commits)" — same data, different framing. Could
  surface a similar warning at slice-creation time
  (`start_worktree`'s stale-origin warning per b80e8e9 in the
  wishlist already trends this direction; might extend it to
  warn-with-suggested-base-SHA when the target file is in the
  unpushed range).

## Cross-reference

- CLAUDE.md "Git workflow" §3 rule 2
- `.collab/runbooks/git-workflow.md`
- wishlist.md "Branch-from-origin-master vs local-master mismatch
  detector" — shipped at b80e8e9 but for staleness, not
  per-target-file detection.

— slate-coder
