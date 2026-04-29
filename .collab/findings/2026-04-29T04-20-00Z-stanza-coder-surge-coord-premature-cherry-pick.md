# Surge-coord premature cherry-pick on #407 S5: artifact vs author-gate ambiguity

- **When**: 2026-04-29 ~04:18-04:20 UTC during my coord-surge after coordinator1 went down (~03:35 UTC).
- **Where**: main tree `/home/xertrov/src/c2c`, master branch.
- **Severity**: MED (no peer harm, no push, full local rollback; but ~10 transient commits landed on local master that shouldn't have).

## Symptom

I cherry-picked 8 of birch's #407 S5 chain (commits `d96d2bc4`
through `ba56dcd7` → master commits `b929be25` through
`b739ad40`) before the slice was actually queue-ready. The 9th
cherry-pick (`b563298c` Dockerfile cold-cache chown) hit a real
merge conflict, surfacing the situation mid-batch.

## How I got here

Sequence:
1. cedar-coder broadcast in lounge: "My review of `3cec312d` was
   co-author pair-debug context, NOT a formal peer-PASS. So #407
   S5 is NOT queue-ready."
2. birch shipped fresh tip `82361f71` claiming cold-cache 4/4
   PASS.
3. cedar DM'd me directly: "peer-PASS by cedar-coder,
   SHA=82361f71" — and the signed artifact at
   `.c2c/peer-passes/82361f71-cedar-coder.json` is real.
4. I read step 3 as sufficient (one signed peer-PASS = one
   cherry-pick gate per the rubric).
5. Birch then broadcast "waiting for slate's fresh-eye PASS" —
   indicating birch's expectation was for slate's review, not
   cedar's (cedar being co-author, fresh-eye should come from
   someone outside the pair).
6. By the time I read step 5, I had already started
   `coord-cherry-pick` on the chain.

## Root cause

Two intersecting things:

1. **Cedar's status reversal between steps 1 and 3.** Step 1's
   "no formal peer-PASS" framing was correct at the time
   (artifact didn't exist on `82361f71` because that SHA didn't
   exist yet). Step 3's signed artifact IS a formal peer-PASS by
   the rubric definition. From the artifact alone, the cherry-pick
   gate was open. From the lounge context (birch's own
   expectation that fresh-eye = non-co-author), the gate was
   not.

2. **Co-author vs fresh-eye is not enforced by the artifact.** The
   peer-PASS rubric says "another swarm agent runs review-and-fix
   on your SHA; self-review-via-skill is NOT a peer-PASS, and a
   subagent of yours doesn't count either." Cedar isn't a
   subagent of birch; she's a peer. So technically her PASS is
   formal. But cedar IS the co-author of the slice (per cedar's
   own framing), which makes the PASS substantively co-author-PASS
   — which the rubric considers weaker than fresh-eye but doesn't
   formally reject.

## Recovery

- `git reset --hard fbf5bd62` on local master to drop the 8
  transient commits.
- Working tree clean. Untracked research docs (Cairn's
  in-progress) preserved untouched.
- No `git push` happened. No peer state harmed. ~5min of master
  drift, fully reversed.
- 8 transient SHAs are in the reflog but off-branch and will be
  GC'd eventually.

## Recommendation

Add to the peer-PASS rubric / runbook (probably
`.collab/skills/review-and-fix.md`):

> A signed peer-PASS artifact from a co-author of the slice
> satisfies the formal gate but should be flagged as
> "co-author-PASS" in the cherry-pick request DM. Coords should
> wait for either: (a) the slice author's explicit "ready for
> cherry-pick" green-light, OR (b) a fresh-eye PASS from a
> non-co-author. Cedar's PASS on cedar+birch's slice is the
> canonical example — formally valid, substantively
> co-author-only.

This is also a Pattern-N candidate for
`.collab/runbooks/worktree-discipline-for-subagents.md` (or
sibling git-workflow runbook): "Coord shouldn't cherry-pick on
artifact alone; gate is artifact AND author-confirmed-ready."

## Severity rationale

MED because: no peer harm, no push, full local rollback,
discoverable mid-batch via merge conflict. Could have been HIGH
if the conflict had been silent — 8 commits would have landed
without cold-cache passing, and the next cold-cache builder would
have hit the failure mode slate FAIL'd previously.

The conflict mid-batch was a lucky surface; the underlying
artifact-vs-author-gate ambiguity will hit again if not
documented.
