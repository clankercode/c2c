# Stale local `origin/master` branch shadows remote ref — `git worktree add` ambiguity

- **When**: 2026-04-29 ~11:14 UTC, hit while creating worktree for #430a.
- **Where**: shared `.git/` of `/home/xertrov/src/c2c/`.
- **Severity**: MED (no data loss, no security; ambient footgun + minutes burned per encounter).

## Symptom

```
$ git worktree add .../430a-jekyll-exclude-superpowers \
    -b slice/430a-jekyll-exclude-superpowers origin/master
warning: refname 'origin/master' is ambiguous.
warning: refname 'origin/master' is ambiguous.
Preparing worktree (new branch 'slice/430a-jekyll-exclude-superpowers')
warning: refname 'origin/master' is ambiguous.
fatal: ambiguous object name: 'origin/master'
```

## Root cause

There's a **local branch literally named `origin/master`** —
`refs/heads/origin/master` — sitting at an older SHA. The actual
remote-tracking ref `refs/remotes/origin/master` is newer.

```
$ git for-each-ref refs/heads/origin/master refs/remotes/origin/master
5474ae28fef71e27be786ec0a5fe9e656afd62a1 commit	refs/heads/origin/master
c2bcd06afe60d9fd668071c2021e9152a242cc73 commit	refs/remotes/origin/master
```

Reflog shows the local branch was `Created from master` (single
creation event, no subsequent updates):

```
$ git reflog show origin/master
5474ae28 origin/master@{0}: branch: Created from master
```

Almost certainly an accidental `git branch origin/master <SHA>` or
`git checkout -b origin/master` somewhere. Once it exists, every
unqualified reference to `origin/master` is ambiguous and git
refuses to resolve it.

## Why it matters for the swarm

CLAUDE.md tells slice authors to **branch from `origin/master`**
(NOT local master). When `origin/master` is ambiguous, they have
two failure modes:

1. **Loud (today's case)**: `git worktree add` errors out and you
   work around with `refs/remotes/origin/master`. ~5 min lost.
2. **Quiet (worse)**: Some git invocations *silently pick* the
   first match. Branching from the stale local branch lands you
   on a SHA missing recent peer commits. The slice builds clean
   in isolation but conflicts later.

Failure mode (2) is the kind of thing that produces a "build
clean here, build red on master" mystery half a day later.

## Workaround

Use the unambiguous ref everywhere a worktree/branch starts:

```bash
git worktree add <path> -b <slice> refs/remotes/origin/master
```

Or fully-qualify in commit-targeting:

```bash
git rev-parse refs/remotes/origin/master
```

## Recommended fix (not yet executed — ownership unclear)

Delete the stray local branch:

```bash
git branch -D origin/master   # safe: never pushed, just shadows remote ref
```

Before doing this on a shared tree, **verify nobody claims it**:

- Reflog shows only the creation event — no commits, no work.
- The branch tip is at `5474ae28`, which is on `origin/master`'s
  history (ancestor check):
  `git merge-base --is-ancestor 5474ae28 c2bcd06a` → 0.

So no work is at risk; it's a pure namespace-pollution branch.
Still, posting in `swarm-lounge` to confirm before pulling the
trigger is the right move per "do not delete shared state without
checking" (CLAUDE.md).

## Future-proofing

`scripts/c2c-tmux*` and the worktree runbooks could add a
preflight: `git for-each-ref refs/heads/origin/* | grep .` and
fail with a clear message if any local branch lives under
`origin/`. Cheap; the ambient footgun is annoying enough that
catching it once at install is worth a few lines.

## Severity rationale

MED, not HIGH: no data loss, no security exposure; the failure is
loud in the worktree-add path that surfaces it. Quiet failure mode
exists but requires a reader to ignore the warning lines, which is
unlikely for someone following the runbook. Still worth filing
because every minute spent diagnosing this is a minute not spent
on slice work, and it's the kind of footgun that recurs (see
#373/#427 sibling rules: shared-tree git ops produce
non-obvious cross-worktree effects).
