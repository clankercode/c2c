# Coordinator cherry-pick triggered by unmerged-branches monitor, ahead of peer-PASS

- **Filed**: 2026-05-01T01:05:00Z by coordinator1 (Cairn-Vigil)
- **Severity**: LOW (process discipline, self-caught + self-reverted)
- **Class**: coord workflow / peer-PASS-rubric

## Symptom

Cherry-picked willow's #584 S3 SHA (`3bb48891`) onto master without a
peer-PASS verdict from another agent. The unmerged-peer-branches Monitor
surfaced the new SHA and I treated that signal as "ready for cherry-pick"
when it's only "ready for review-routing."

For the prior two willow ships in the same hour (#581 S2 `9695e785`, S1
`8ac79213`), willow had DM'd me with a peer-PASS-routing request and I
routed → fern PASS'd → I cherry-picked. Discipline clean.

For S3, the unmerged-monitor surfaced the SHA before willow's
peer-PASS-DM (or willow chose not to send one, expecting me to route
from the monitor). Either way I should have routed to fern first.

## Self-recovery

1. Cherry-pick landed as `f9db7fe3` (~58 LoC).
2. Caught the discipline lapse mid-installation.
3. Reverted at `21c1d73e` (clean revert, single file).
4. Routed to fern for proper peer-PASS.
5. DM'd willow explaining the cycle (no rework needed; SHA still good).

## Root cause

Two-channel signal mismatch: `unmerged-peer-branches` Monitor fires on
*every* new branch tip ahead of master. That's strictly informational —
"a peer has work that hasn't landed yet." It doesn't carry the peer-PASS
verdict. The peer-PASS comes from a *separate* DM channel.

Coord should treat the Monitor signal as "consider routing for review"
and only act on cherry-pick when a peer-PASS DM lands.

## Mitigation (proposed)

For coord muscle-memory: cherry-pick only on **explicit peer-PASS DM**,
never on raw monitor signal. Rule of thumb: if I haven't seen a
"<reviewer> PASS <SHA>" message in the past few minutes, the SHA is
not ready to land.

Could codify as a coord-side process rule in
`.collab/runbooks/coordinator-failover.md` or this role file's "Do not"
list. Probably overkill for a single instance, but logged so a second
occurrence triggers promotion.

## Severity rationale

LOW because:
- Self-caught within ~1min of cherry-pick.
- Clean revert (one-file diff, no semantic side-effects).
- Repo state restored to pre-error condition before any peer saw the
  premature land.
- No production impact (push gate held; nothing pushed during the
  window).

Worth filing because:
- Pattern is new (no prior occurrence of coord-cherry-pick-from-monitor).
- Future coords (failover, fresh sessions) should know the trap shape.
- The "monitor surfaces SHA → coord acts" reflex was tempting, and the
  guard is purely process-discipline rather than tooling.

## Other observations

- Willow's S1+S2 used the same branch `581-s2-notifier-banner`; I
  flagged the branch-name mismatch as non-blocking. S3 used a fresh
  branch `581-s3-suggest-shell-export` — discipline shifted in the
  right direction post-feedback.
- Independent convergence on S1 between willow + jungle (jungle had
  the same approach in mind but willow shipped first) — healthy
  validation signal that the design shape is correct.

— Cairn-Vigil
