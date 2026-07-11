# Plan review v2 — friction-points-cn closure

## Scope

- Reviewed commit `5cabf8332a080c2a6298e43abdd040a1ac02d01e`.
- Compared only `outputs/plan.md` against the five FAIL findings in `reviews/plan-v1.md`.
- Attempted to find a new blocker introduced by the corrective edits; did not reopen broader source-report, backlog, or implementation questions.

## Prior FAIL issues

| Prior issue | Corrective evidence in plan v2 | Result |
|---|---|---|
| 1. Audit worktree bases undefined | Root context records the exact prerequisite tip; T0 and T1-T3 each name `c8d5e7c93070058907fa5f342c23c45f63772b2e`; AC5 and T4 require every later slice to classify and record its base/prerequisite. | Fixed |
| 2. Reviewer fallback could not satisfy peer-PASS | Root context now says subagents do not satisfy peer-PASS; AC9 makes real-live-peer review with `build-clean-IN-slice-worktree-rc=0` a final-closure requirement; TV requires current tip/range review, in-worktree build/check, new fix commits, and re-review. | Fixed |
| 3. Live relay dogfood was optional | AC10 makes relay evidence and operator-confirmed state-changing dogfood part of closure; TV requires timestamped command/exit-code evidence, existing tmux/relay harnesses, and a blocking gap when authorization or access is unavailable. | Fixed |
| 4. Complete inventory was deferred until synthesis | AC1 and T0 require a stable-row, all-source inventory with the previously missing schema and a review before implementation dispatch; TR consumes every unresolved row; TV re-audits it at closure. | Fixed |
| 5. Parallel audits had unresolved dependencies | TR is an explicit post-audit/pre-implementation gate, names B089↔I002 and B096↔I004, and requires a reviewed ordered dependency graph before dispatch. | Fixed |

## Attempted decisive criticisms

### A. Could supplemental subagent review still bypass the real-peer gate?

No. The plan permits subagent audit/self-review while no peer is live, but AC9 and TV unambiguously block final closure until a real live peer reviews every changed slice tip/range and records the required in-worktree build criterion. This is the distinction requested by plan-v1 rather than the rejected fallback.

### B. Could live verification still be silently replaced by hermetic evidence?

No. T1 retains a useful warning that network access may be needed, while AC10 and TV prohibit closure when required state-changing relay proof lacks authorization/access. TV also requires read-only public-relay checks and exact evidence capture. The remaining operator-confirmation dependency is an explicit blocker, not an escape hatch.

### C. Could T0/TR become ceremonial and allow early implementation dispatch?

No. AC1, T0, TR, and T4 all state the same ordering constraint: the complete inventory and reconciliation review precede creation/dispatch of implementation slices. TR also specifies how every unresolved row must become either bounded work or an authority-backed disposition.

### D. Could later implementation slices again inherit an ambiguous base?

No blocker found. AC5 requires per-slice base classification; T4 states the default prerequisite-bearing base, the condition for using `origin/master`, and the requirement to record the choice. The exact future SHA is correctly deferred until slice creation because it must reflect the then-current prerequisite tip.

## New-blocker check

The corrective edits do not introduce a new blocker. They add gates and evidence obligations without authorizing push/deploy, silently reversing deferred product decisions, or weakening the original acceptance criteria. Peer and public-relay availability may block execution later, but the plan now treats both as explicit closure conditions, which is correct.

## Verdict

**PASS.** All five prior decisive FAIL issues are fixed, and the narrow regression pass found no new blocker introduced by the edits.
