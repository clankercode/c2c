# Friction-points-cn closure plan

## Root IGC

- Idea: treat `friction-points-cn.md` as a complete product/engineering intake, not merely a historical report.
- Goal: prove every reported friction point has either (a) a verified implementation with tests/docs, or (b) an explicit, still-valid product disposition with dependencies and rationale; implement every actionable, non-deferred gap found.
- Context: local `master` is 35 commits ahead of `origin/master`; the original 14 bugs B087-B100 are marked done, while B101 and ideas I002-I008 capture remaining or follow-on work. All audit worktrees were deliberately created from prerequisite-bearing local-master tip `c8d5e7c93070058907fa5f342c23c45f63772b2e`, not stale `origin/master`, because the fixes being audited are absent from origin. No live c2c coordinator/peer is currently registered; fresh-slate collaboration subagents may audit and self-review, but they do not satisfy the repo's real-peer-PASS landing gate.

## Acceptance criteria

1. Before implementation dispatch, a reviewed matrix covers every normative report item—not only B/I backlog entries—including recommendations, product/website positioning, information architecture, six milestones, test/conformance expectations, architectural decisions, and top actions. Every row has a source heading/line, requirement, evidence, backlog link or new task, disposition authority, dependencies, required tests/docs/live proof, and closure state.
2. Done backlog items B087-B100 are independently checked against current local master; status alone is not accepted as proof.
3. B101, I002, and I005 are either implemented and verified or rejected/deferred only with decisive evidence and an operator-level decision already present in the repository.
4. I003, I004, I006, I007, and I008 retain their recorded product decisions; dependencies, rationale, and any implementation gap are surfaced, not silently treated as complete.
5. Every code/doc slice is isolated in its own worktree, committed, reviewed, and tested in that worktree. Fixes use new commits. Every slice records whether its base is independent `origin/master` or a chain/prerequisite SHA; friction fixes depending on B087-B100 use a refreshed prerequisite-bearing local-master tip.
6. Focused tests run during implementation; `just check` and the full relevant suite run before final synthesis.
7. A final re-audit finds no unclassified report item and the manual CORE verifier passes.
8. Nothing is pushed; the coordinator/deployment gate remains intact.
9. Final closure requires a real live c2c peer to review every changed slice tip/range and record `build-clean-IN-slice-worktree-rc=0`; collaboration subagent review is supplemental only.
10. Relay-facing claims include read-only public-relay evidence plus operator-confirmed state-changing dogfood where required. If state-changing public-relay verification is not explicitly authorized or cannot run, final closure remains blocked and says so.

## Failure criteria

- Any report item lacks a traceable evidence row or explicit disposition.
- A backlog `done` marker is used without checking behavior/tests/docs.
- An explicitly deferred architectural decision is silently implemented or reversed.
- A user-facing behavior changes without matching help/docs/tests.
- A task is synthesized without review evidence, or verifier state contains unresolved blockers.

## Task decomposition

### T0 — Complete source-to-evidence inventory

- Base: prerequisite-bearing local-master tip `c8d5e7c93070058907fa5f342c23c45f63772b2e`.
- Scope: all 2,836 lines/headings of `friction-points-cn.md`, including material not represented by B087-B101/I002-I008.
- Output: committed `.collab/research/friction-cn-complete-inventory.md` with stable row IDs and the fields required by AC1.
- Review: independent audit reviewer must attempt to find an omitted or misclassified normative item before implementation dispatch.
- Blockers: suggestions are not silently promoted to requirements; disposition must cite source wording or recorded operator/product authority.

### T1 — Historical bug closure audit (B087-B094)

- Worktree: `.worktrees/friction-cn-audit-bugs`
- Base/prerequisite: exact local-master tip `c8d5e7c93070058907fa5f342c23c45f63772b2e`; this is a chain audit because B087-B094 are absent from `origin/master`.
- Scope: installer fallback, relay discovery/connect, truthful remote send, unified relay receive, subscribe hint, doctor, status/whoami.
- Output: committed `.collab/research/friction-cn-b087-b094-audit.md` with per-item evidence, decisive criticisms attempted, and gaps.
- Blockers: live public-relay checks may need network; distinguish hermetic evidence from live evidence.

### T2 — Safety/docs/discovery closure audit (B095-B100)

- Worktree: `.worktrees/friction-cn-audit-contract`
- Base/prerequisite: exact local-master tip `c8d5e7c93070058907fa5f342c23c45f63772b2e`; this is a chain audit because B095-B100 are absent from `origin/master`.
- Scope: connect naming, relay peek semantics, unified list/identity, bus-never-RPC invariant, untrusted-data adapter framing, golden-path docs.
- Output: committed `.collab/research/friction-cn-b095-b100-audit.md`.
- Blockers: safety claims require regression-test evidence across all delivery adapters.

### T3 — Pending/future disposition audit (B101, I002-I008)

- Worktree: `.worktrees/friction-cn-audit-futures`
- Base/prerequisite: exact local-master tip `c8d5e7c93070058907fa5f342c23c45f63772b2e`, so partial implementations and recent decisions are visible.
- Scope: exact acceptance criteria, dependency graph, current partial implementations, and whether each item is actionable now or explicitly deferred.
- Output: committed `.collab/research/friction-cn-pending-futures-audit.md` plus proposed bounded implementation slices.
- Blockers: do not override the recorded trusted-swarm-first decisions.

### TR — Cross-audit reconciliation and inventory review

- Runs after T0-T3 and before any implementation slice is created.
- Reconcile at minimum B089↔I002 (unified monitor exists but canonical versioned JSON may not) and B096↔I004 (non-destructive peek exists while server-side delivery cursors/read receipts remain deferred).
- Merge audit findings into an ordered dependency graph. Every unresolved T0 row becomes a bounded implementation task or an explicit disposition backed by operator/product authority.
- Review gate: no implementation dispatch until an independent reviewer fails to find a contradictory status, missing row, or dependency inversion.

### T4+ — Implement proven gaps

- Created only after T0-T3 and TR review.
- Each independent slice gets a new worktree and file ownership boundary.
- Required likely slices: B101 package-manager self-update, I002 schema contract, I005 fake-relay regression fixture; audit may narrow or expand this set.
- Base selection: because these changes build on local-only B087-B100/0.10.0 behavior, default to the latest prerequisite-bearing local-master SHA recorded at slice creation. Use `origin/master` only if the slice audit proves it has no dependency on those commits. Record the choice in the slice artifact.
- Blockers: slice dependencies and pre-existing test failures are recorded before work starts.

### TV — Verification and final closure audit

- Run focused tests per slice, then `just check` and full relevant tests.
- Run review-and-fix and the implementation skill's code-review gate.
- Reconcile the evidence matrix against all headings/top actions in `friction-points-cn.md`.
- Run read-only public-relay checks (`relay status`, identity/lease/status surfaces, `doctor --relay --json`) and save exact commands/exit codes/timestamps.
- Before any state-changing public-relay send/register/connector dogfood, record explicit operator confirmation in CORE state. Then use existing repo/tmux harnesses (`scripts/c2c_tmux.py` and maintained relay scripts), not ad-hoc client spawns. Save exact evidence. If confirmation/access is absent, record a blocking gap rather than equating hermetic evidence with live proof.
- Obtain real-peer review of each changed tip/range. The reviewer must build/check inside that slice worktree and include `build-clean-IN-slice-worktree-rc=0`; all fixes are new commits and re-reviewed.
- Run `udwff-verify-run` before reporting completion.

## Workflow choices

- Interactivity: autonomous, because the operator requested complete execution and existing backlog records already contain product decisions.
- Inter-agent comms: collaboration SendMessage for worker control; c2c CLI for live-peer review if a peer appears. Correctness facts are mirrored into CORE events.
- Extensions: none discovered in the allowlisted `wff-*` paths.
- Escalation: destructive/remote/push actions, secrets, product decisions lacking an objective or already-recorded default, and exhausted review routes.
- Models/budgets: platform defaults; no operator override requested.
- Safety: local-only writes in isolated worktrees; no push/deploy.
