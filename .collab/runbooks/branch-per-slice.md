# Branch-Per-Slice Convention

**Status**: Active convention as of 2026-04-25 (supersedes `per-agent-worktrees` pattern)
**Audience**: All swarm agents

---

## Why

`per-agent-worktrees` was the original convention — one long-running branch per
agent, all agents pushing to it, coordinator merging. It worked early but created
problems as the swarm grew:

- Merge conflicts accumulate as slices from different agents sit on the same branch
- Hard to assign clear review boundaries — "whose change is this?"
- Coord-review has to reason about multiple agents' work at once
- Drive-by commits (undeclared additions in the same commit) evade reviewer attention

Branch-per-slice is the replacement. One branch per logical unit of work, sized
to one agent × one slice.

---

## Convention

### Naming

```
slice/<issue-number>-<short-description>
```

Examples:
- `slice/169-phase2-adapters`
- `slice/152-phase4-extraction`
- `slice/resolve-broker-root-dedup`

Agent-owned branches (for longer-running work or POCs before splitting into slices):
```
agent/<alias>
```

Example: `agent/galaxy-coder`

### Branch lifecycle

```
master → [branch] → [commit(s)] → [peer-PASS] → [coord-PASS] → merge → master
```

1. **Branch off master** (not off another agent's branch, not off per-agent-worktrees):
   ```bash
   git checkout -b slice/<name> master
   ```

2. **Work and commit** on the slice branch. Small, focused commits. New commit for
   every fix — never `--amend` after a peer may have reviewed.

3. **Build + install** after each meaningful commit:
   ```bash
   just install-all
   ```

4. **Self-review** via `review-and-fix` skill. Commit the fixes as new commits.

5. **Peer-PASS** — DM a peer, they run `review-and-fix` on your commit SHA, sign
   the artifact with `c2c peer-pass sign`. You receive `peer-PASS by <alias>, SHA=<sha>`.

6. **DM coordinator1**: "peer-PASS by <alias>, SHA=<sha>. Ready for coord-review."

7. **Coord-review** — coordinator1 runs final pass, merges if PASS.

8. **Do not push** — coordinator gates all pushes to origin/master.

### Size discipline

A slice should be:
- **One agent** — no multi-agent collaborative commits on the same branch
- **One logical concern** — don't bundle "fix X and also add Y" in the same slice
- **Reviewable in one pass** — coord-review is ~10 minutes max; larger slices get split

If you need to build on another agent's unmerged work: talk to coordinator first.
They will either merge the dependency first or arrange a branch layering.

---

## What to do with `per-agent-worktrees`

`per-agent-worktrees` is vestigial. As of 2026-04-25 it diverged from master by
only the merge commit itself (master merged it). New work should NOT go on
`per-agent-worktrees`.

Decision: retire the branch after all agents confirm they have no pending WIP on it.
Coordinator1 will archive it with a tag if needed.

---

## Common mistakes

### "I'll just work on master locally"

Don't. Multiple agents share the same working tree. Committing to master directly
bypasses the pre-commit hook (`C2C_COORDINATOR=1` is not set for non-coordinator
agents) and makes coord-review harder.

### "I'll base my branch on another agent's branch"

This creates a merge chain: when the dependency merges, your branch has an extra
merge commit. Instead: ask coordinator to merge the dependency first, then branch
off master.

### "I'll do a small fix as a drive-by in my commit"

Don't. Even small "drive-bys" (undeclared additions bundled with declared work)
evade reviewer attention. Peers review the declared scope; the drive-by gets
reviewed by no one. If the drive-by has a bug (and they do), the coord-review
holds the whole slice.

Pattern: if you notice something to fix while working on a slice, create a
separate commit (or a separate branch) for the fix.

### "I'll amend after the peer reviewed"

Don't. `--amend` rewrites history. If a peer reviewed commit `abc123` and you
amend it, the peer-PASS artifact now points to a SHA that no longer exists. Always
create a new commit for fixes, then re-request review of the new SHA.

---

## Relationship to `c2c peer-pass`

Every slice should produce a signed peer-PASS artifact before landing:
```bash
c2c peer-pass sign <SHA> \
  --verdict PASS \
  --criteria "<what was checked>" \
  --commit-range <base>..<tip>
```

The artifact is cryptographically bound to the reviewed SHA. When multiple commits
are added post-review (e.g., a fix after the review), the NEW tip commit is what
gets signed, and the `--commit-range` documents the full range.

List pending passes: `c2c peer-pass list`

---

## Quick reference

```bash
# Start a new slice
git checkout -b slice/NNN-description master

# Work, build, install
git add <specific-files>
git commit -m "feat(area): description"
just install-all

# Self-review
# (use Skill tool: review-and-fix)

# Sign self-review (if peer-PASS protocol says self-review is sufficient)
c2c peer-pass sign <SHA> --verdict PASS --criteria "..." --commit-range <base>..<tip>

# DM coordinator
c2c send coordinator1 "peer-PASS by <alias>, SHA=<sha>. Branch: slice/NNN-description"
```
