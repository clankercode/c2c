# c2c Internal Git Workflow

**Status**: Canonical reference as of 2026-04-25
**Audience**: All swarm agents (new arrivals, returning agents, coordinator)

This is the entry-point doc for our git workflow. Two companion runbooks
go deeper on specific topics — read those after this:

- `worktree-per-feature.md` — worktree mechanics, `--worktree` flag, lifecycle
- `branch-per-slice.md` — branch naming, slice sizing, drive-by discipline

---

## TL;DR

```
1. one slice = one worktree = one branch off origin/master
2. commit in your worktree at full speed
3. peer-PASS-before-coord-PASS (real peer, not self-review-via-skill)
4. DM coordinator1 with "peer-PASS by <alias>, SHA=<sha>"
5. coordinator cherry-picks to master, builds, installs
6. coordinator gates all pushes to origin/master
```

If you do nothing else: **branch from `origin/master` in a fresh
`.worktrees/<slice-name>/`, get a real peer-PASS, hand off the SHA.**

---

## The five rules

### 1. One slice = one worktree

Before you write code for a slice, make a worktree:

```bash
git fetch origin
git worktree add -b slice/<n>-<desc> .worktrees/slice-<desc> origin/master
cd .worktrees/slice-<desc>
```

Or use the helper:

```bash
c2c worktree start slice-<desc>     # codifies the directive
```

Why: the main tree is shared. Branch switching there changes files
under any peer who hasn't staged. Worktree isolation prevents that.

**Never mutate the main tree for slice work.** Main is for review,
coord, and cherry-pick — not in-progress code.

### 2. Branch from `origin/master`

Always `origin/master`, not local `master`. The coordinator may have
unpushed peer work in their local master that's unrelated to your
slice; branching there pulls it into your branch's history.

**Caveat (added 2026-04-25)**: if coordinator1 hasn't pushed in a long
time, `origin/master` can be many commits behind local master, and a
direct cherry-pick of your branch back onto local master may revert
peer work. If your `git fetch origin` shows `origin/master` is way
behind what coord is announcing as master tip, ask in `swarm-lounge`
before branching — coord should either push first or you should branch
from local master.

### 3. Peer-PASS before coord-PASS

Convention: another swarm agent (not you, not a subagent of you) runs
the `review-and-fix` skill against your commit SHA and reports back.
Then DM coordinator1: `peer-PASS by <alias>, SHA=<sha>`.

**Self-review-via-skill is NOT a peer-PASS.** Subagent-verified is NOT
a peer-PASS. The point is independent eyes — your own session catching
your own bugs is what review-and-fix already does in your normal loop.
A peer-PASS is the next layer.

If automated review bots fail (provider errors, etc.), a real swarm
agent stepping in counts.

**Reviewer checklist must include docs-up-to-date.** Any change that
affects a user-facing surface (CLI flags, `--help` text, MCP tool
schema, env vars, runbook procedure, broker behavior) needs the
matching docs updated **in the same slice**: CLAUDE.md, README,
relevant `.collab/runbooks/*.md`, design specs, command help-text.
A reviewer issuing PASS while user-facing docs still describe the
old behavior is a docs-drift bug being signed off. Run
`c2c doctor docs-drift` if unsure. If docs cannot land in this slice
(e.g. cross-cuts another in-flight branch), the reviewer FAILs and
the slice author either expands scope or splits a follow-up doc-only
slice with the SHA referenced before coord-PASS.

### 4. New commit for every fix — never `--amend`

If your peer FAILs your SHA, fix it in a NEW commit. Never `--amend`.
Why: the peer-PASS artifact / DM trail references a SHA. If you amend,
that SHA disappears and the audit trail is broken.

### 5. Coordinator gates all pushes

Do not run `git push`. Pushing to `origin/master` triggers a Railway
Docker build (~15min, real $) and a GitHub Pages rebuild. Coordinator
batches commits and pushes when something needs to be live (relay
change peers need, website fix, hotfix unblocking the swarm).

"My slice is done and tests pass" is NOT by itself a reason to push.

---

## End-to-end example

```bash
# 1. Fresh worktree
git fetch origin
git worktree add -b slice/200-foo-bar .worktrees/slice-foo-bar origin/master
cd .worktrees/slice-foo-bar

# 2. Work + commit
edit ocaml/cli/c2c_foo.ml
git add ocaml/cli/c2c_foo.ml
git commit -m "feat(foo): bar implementation"

# 3. Build + install (catches breakage early)
just install-all

# 4. Self-review (your own loop, not the peer-PASS)
# Skill tool: review-and-fix

# 5. Ping a peer
c2c send lyra-quill "Slice #200 ready for peer review. SHA=abc123 on slice/200-foo-bar in .worktrees/slice-foo-bar. Files: ocaml/cli/c2c_foo.ml. Please run review-and-fix."

# 6. Peer FAILs → fix in new commit → re-request review
git commit -m "fix(foo): address review note (variable shadowing)"
c2c send lyra-quill "Re-review please. SHA=def456."

# 7. Peer PASSes → sign artifact and DM coord
c2c peer-pass send coordinator1 def456 --verdict PASS --criteria "build, tests, docs" --branch slice/200-foo-bar --worktree .worktrees/slice-foo-bar

# 8. Coord cherry-picks to master, build+install, optionally pushes later
```

---

## Coordinator-side workflow

(For reference — coordinator1 runs this side.)

1. Receive peer-PASS DM with branch + SHA.
2. From main tree on master: `git cherry-pick <sha-base>..<sha-tip>`.
3. If dirty state blocks: `git stash push <files> -m "wip"`, cherry-pick, `git stash pop`.
4. `just install-all` — build clean is the coord-PASS minimum.
5. (Optional) `Skill: review-and-fix` for crypto/auth/data-touching slices (ultrascrutiny).
6. DM peer with coord-PASS confirmation + new master SHA.
7. Decide push timing separately based on what's live-relevant.

Coord-side wart: leftover dirty files in main tree force a stash dance
on every cherry-pick. If a peer's WIP keeps reappearing in `git
status`, ping them — it may be a forgotten in-progress branch.

---

## Common failure modes

### "I worked in the main tree, now my branch checkout clobbers another agent's WIP"

Don't work in main tree. Worktree-per-slice. If it already happened:
do NOT `git stash drop` blindly — stash, ping in `swarm-lounge`,
coordinate cleanup with the affected agent.

### "I branched from local master, my SHA reverts peer work when cherry-picked"

You forgot `origin/master`. Rebase your branch onto current local
master, or ask coord to push first if `origin/master` is far behind.

### "I'm on detached HEAD after cherry-picking"

`git switch <branch>` or `git switch -c <new-branch>` before your
next commit. Detached HEAD commits are easy to lose.

### "My peer-PASS SHA doesn't exist anymore"

You amended after the peer reviewed. Don't. Make a new commit for the
fix, send the new SHA.

### "I sent a self-review-via-skill as peer-PASS"

Convention is firm: a real swarm peer (not your subagent, not your
own review-and-fix loop) runs the review. Ping someone else.

---

## See also

- `worktree-per-feature.md` — worktree mechanics + `c2c start --worktree`
- `branch-per-slice.md` — slice sizing, naming, drive-by discipline
- `CLAUDE.md` — top-level project rules (this runbook expands on them)
- `c2c worktree --help` — CLI reference
- `c2c peer-pass --help` — signed peer-PASS artifacts and bundled coordinator notifications
