# Coord Workflow + Peer-PASS Process

**Status**: active

## Goal
Coordinator surface (cherry-pick, peer-PASS rubric, push-gate, install-path policy) is mature enough that swarm-cycles don't need Max-direct intervention.

## Key items
- #323 — auto-DM-on-cherry-pick landed
- #324 — peer-PASS rubric live
- #325 — divergent-base runbook landed
- #334 — PUSHED
- #360 — FIXED (`99d7b6cf` — two-phase copy, dry-run, fail-loud)
- Phantom-reviewer cascade finding filed (`2026-05-02T08-45-00Z-coordinator1-phantom-reviewer-cascade`)
- Chain-slice diff guidance added
- Findings triage (birch, 2026-05-04) — closed 3 OPEN findings, 1 partially closed

## Open
- #352 — doctor migration-prompt (unblocked by #360)
- #328 — coord-cherry-pick scope-audit + auto-build deferred

## References
- `todo-ongoing.txt` entry: Coord workflow + peer-PASS process
- Cluster: #323/#324/#325/#334/#360
- Rubric: `.collab/runbooks/git-workflow.md`
