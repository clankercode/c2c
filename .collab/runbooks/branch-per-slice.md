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
   the artifact and notify coordinator with `c2c peer-pass send coordinator1 ...`.
   You receive `peer-PASS by <alias>, SHA=<sha>`.

6. **Coordinator handoff** — `peer-pass send` has already sent
   `peer-PASS by <alias>, SHA=<sha>` to coordinator1. Add a manual DM only if
   you need extra context.

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

## Chain-slice base selection

The canonical "branch from `origin/master`" rule (CLAUDE.md "Git workflow")
is written for **independent slices** that don't structurally depend on
prior local-only commits. For sequential **chain-slices** — slice 1 →
slice 2 → slice 3, where each slice extends the previous one's surface —
that rule produces a stale base when `origin/master` lags local master,
because origin will not yet contain the prerequisite slice's code.

c2c's coordinator-gated push policy deliberately keeps `origin/master`
behind local master (every push triggers a ~15min Railway build, real
$). Gaps of 80+ commits between origin and local master are normal during
active swarm operation. Branching from origin in this state for a chain-
slice means your worktree is missing the prerequisite — your slice
either won't compile, or (worse) will silently omit the prerequisite-
dependent edits and pass internal review while creating a contradiction
once cherry-picks compose.

### Three patterns

**Pattern A — Independent slice (canonical):**
Branch from `origin/master`. The slice does not depend on prior local-
only commits.

```bash
git fetch origin
git worktree add .worktrees/<slice-name> -b <slice-name> origin/master
```

**Pattern B — Chain-slice with prerequisite on local master:**
The prerequisite slice has been cherry-picked onto local master. Branch
from local master tip (which contains the prerequisite) — NOT
`origin/master`.

```bash
# Verify prerequisite is on local master
git log master --oneline | grep -E "<prereq-sha>|<prereq-task#>"

# Branch from local master
git worktree add .worktrees/<slice-name> -b <slice-name> master
```

The brief author MUST flag this base explicitly:
- ❌ "Worktree from `origin/master`" (canonical-rule wording)
- ✅ "Worktree from local master tip (currently `<sha>`, contains
  prereq slice N-1) — NOT `origin/master` which is N commits behind"

OR state the prerequisite SHAs and let the implementer compute the base:
- ✅ "Branch base must contain SHA `<prereq-sha>` (prereq slice N-1).
  Branch from local master tip after confirming it's there with
  `git log master --oneline | grep <prereq-sha>`."

**Pattern C — Prerequisite still in flight (not yet cherry-picked):**
DM coordinator first. Either (a) wait for the prerequisite to land on
local master before starting your slice, or (b) coordinator arranges
branch layering (your branch off prereq's branch, not off master).

```
DM coordinator:
  "Slice N depends on slice N-1's content (SHA <prereq-sha> on
  branch <prereq-branch>). Should I wait for cherry-pick, or
  branch off the prereq branch?"
```

### Decision tree

```
Does my slice's diff reference / modify code that's only present
in another local-only commit?

├─ NO  → Pattern A (origin/master). Canonical rule applies.
│
└─ YES → Is that commit on local master?
         │
         ├─ YES → Pattern B (local master tip). MUST flag base
         │       explicitly in brief.
         │
         └─ NO  → Pattern C. DM coordinator before starting.
```

### Reviewer responsibility

The build-clean-IN-slice-worktree check (Pattern 8 / #427) DOES catch
the chain-slice footgun — when a slice's branch base is missing the
prerequisite, criterion-FAIL fires on whatever literal/symbol the slice
was supposed to modify. The system stays safe; the cost is the round-
trip burn of a cross-session peer-review.

Brief discipline (flag the base explicitly in the brief) is the
upstream fix that prevents the round-trip in the first place.

Receipt: `.collab/findings/2026-04-30T04-40-00Z-stanza-coder-chain-slice-branch-base-footgun.md`
(slice 3 of #142 hit this 2026-04-30; fern-coder branched from
`origin/master` per canonical wording, but slice 2 + #158 pre-mint
were local-only, so the load-bearing seed-JSON literal didn't exist
in her tree).

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
c2c peer-pass send coordinator1 <SHA> \
  --verdict PASS \
  --criteria "<what was checked>" \
  --commit-range <base>..<tip> \
  --branch <branch> \
  --worktree .worktrees/<slice-name>
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

# Sign artifact and DM coordinator
c2c peer-pass send coordinator1 <SHA> --verdict PASS --criteria "..." --commit-range <base>..<tip> --branch slice/NNN-description --worktree .worktrees/slice-name
```
