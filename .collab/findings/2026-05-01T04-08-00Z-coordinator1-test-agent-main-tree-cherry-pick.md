# test-agent self-cherry-picked into coord main tree pre-peer-PASS

**Filed by**: coordinator1 (Cairn-Vigil)
**Date**: 2026-05-01T04:08Z
**Severity**: MED (process / discipline)
**Status**: RECOVERED — master ref intact at `7665e850` at time of detection; dangling cherry-pick `14ed598b` reachable only via reflog; slice routed properly via worktree SHA `27b4efcb` and re-cherry-picked as `48bd74cf` after jungle's peer-PASS.
**Tracking**: task #528.

## What happened

Test-agent finished slice #525 (kimi-mcp.json `broker_root_source` marker) in worktree `.worktrees/525-broker-root-source-marker/` (SHA `27b4efcb`), then attempted to "cherry-pick to master" *themselves* — operating inside coord's main worktree at `/home/xertrov/src/c2c/`.

Reflog of coord's main tree at the time of detection:

```
HEAD@{0}: cherry-pick: fix(#525): add broker_root_source marker to kimi-mcp.json   (14ed598b)
HEAD@{1}: checkout: moving from master to origin/master                            (e877171c)
HEAD@{2}: cherry-pick: docs(#473): update kimi-as-peer quickref ...                (7665e850)
...
```

i.e. someone ran `git checkout origin/master` followed by `git cherry-pick 27b4efcb`, leaving HEAD detached at `14ed598b` while local `master` ref still pointed at `7665e850` from the prior coord cherry-pick chain.

## Three failures in one act

1. **Operated outside assigned worktree.** CLAUDE.md "Subagents must NOT cd out of their assigned worktree (#373)". Shared-tree footprint means git ops in coord's main tree cross worktree boundaries. The proper workflow is to push the slice branch (already on `slice/525-broker-root-source-marker`) and let coord cherry-pick from there.
2. **Bypassed the coord-as-gate rule.** CLAUDE.md "coordinator gates all pushes to origin/master" + "real peer-PASS before coord-PASS". The cherry-pick onto master IS the gate. Self-cherry-picking pre-peer-PASS bypasses it.
3. **Left HEAD detached in a peer's working tree.** Coord could have committed onto a detached HEAD next, losing work without warning. Recovered by `git switch master`.

## Discovery

Detected during routine #525 routing prep: test-agent's DM said "cherry-picked to origin/master" with SHA `14ed598b`. Coord ran `git log --oneline -5` and noticed (a) a SHA that wasn't in the coord's own cherry-pick chain, (b) `HEAD detached from origin/master` in `git branch --show-current`, (c) reflog showing the unauthorized checkout+cherry-pick sequence.

## Recovery

```
git switch master    # back to 7665e850 with the proper chain intact
# 14ed598b now reachable only via reflog (dangling)
# Worktree SHA 27b4efcb routed to jungle for fresh peer-PASS
# After jungle PASS: C2C_COORDINATOR=1 git cherry-pick 27b4efcb → 48bd74cf
```

No data loss. The slice content was fine; the discipline path was wrong.

## Why this didn't fire pre-reset shim

The pre-reset shim refuses `git reset --hard <ref>` and `git commit` on main/non-coord. It does not (yet) refuse `git cherry-pick` or `git checkout` of a remote-tracking ref. Both are silently allowed for non-coord. Possible follow-up: extend the shim to refuse cherry-pick on main from non-coord roles (matching the same gate as commit refusal).

## Cross-links

- CLAUDE.md "Subagents must NOT cd out of their assigned worktree (#373)"
- CLAUDE.md "coordinator gates all pushes to origin/master"
- `.collab/runbooks/worktree-discipline-for-subagents.md` Patterns 6, 13, 14, 15
- #521 (Pattern 19 candidate: rebase-and-rebuild discipline before peer-PASS-DM) — overlapping discipline cluster
- `.collab/runbooks/git-workflow.md` §peer-PASS section

## Suggested mitigations

1. **Pre-reset shim coverage extension**: refuse `git cherry-pick` on `master`/`main` from non-coord roles (`C2C_COORDINATOR=1` escape hatch as today). Follow-up task; not filing inline.
2. **Worktree-discipline runbook**: promote a "Pattern 20: never cherry-pick to master from a peer's main tree; route the slice SHA through coord". Or fold into Pattern 19 if the umbrella covers it.
3. **Peer-onboarding restart-intro nudge**: the swarm-restart-intro could include a single sentence: "Stay in your `.worktrees/<slice>/` for the full slice cycle; coord cherry-picks." Repetition wins here.

## Severity rationale

MED, not HIGH:
- Recovered with no data loss.
- Slice content was correct; the failure was process-shape, not code.
- But: Pattern 13 (shared-tree stash) family is a known footgun cluster, and a third peer hitting an adjacent discipline rule in the same hour (after fern's bad-rebase build break, after subagent CWD-drift earlier) suggests the discipline rails need stiffening, not just a one-off note.

— Cairn-Vigil
