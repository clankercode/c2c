# Plan review v1 — friction-points-cn closure

## IGC checked

- Idea: review `outputs/plan.md` as the execution contract for completely addressing `friction-points-cn.md`, not as an informal outline.
- Goal: find any decisive coverage, scope, dependency, worktree, review, or verification defect that would permit a false closure.
- Context: reviewed plan SHA-256 `87a57124000d728ed8326f9f80be08f68dae292f720d16a34bc137f845d95d79`; source-report SHA-256 `26ac721bc2740ff86d14f25e650ba3c9dc20c46e9d6a92b71988ab2ae18c3718`; backlog items B087-B101 and I002-I008; `AGENTS.md`; and the git/worktree review runbooks. At review time `master` was exactly 35 commits ahead of `origin/master` (`master=c8d5e7c93070058907fa5f342c23c45f63772b2e`, `origin/master=1bb6b4aab908ba2ac57f4508718add7850294b92`).

## Backlog disposition check

| Item | Recorded disposition | Plan treatment | Review result |
|---|---|---|---|
| B087 | done; audit relay-connect parsing, identity, and non-zero failure | T1 independently audits | valid, subject to live proof |
| B088 | done; audit truthful queued/accepted reporting | T1 independently audits | valid |
| B089 | done; audit relay-aware receive | T1 independently audits | valid only after reconciliation with I002 |
| B090 | done; audit HTTPS fallback hint | T1 independently audits | valid |
| B091 | done; audit default relay discovery/help/docs | T1 independently audits | valid |
| B092 | done; audit old-npm installer fallback | T1 independently audits | valid |
| B093 | done; audit relay doctor/capabilities/outbox | T1 independently audits | valid |
| B094 | done; audit status/whoami/addressing | T1 independently audits | valid |
| B095 | done; audit connect/ping naming | T2 independently audits | valid |
| B096 | done; audit non-destructive relay peek/cursor semantics | T2 independently audits | requires reconciliation with I004's “cursors do not exist” premise |
| B097 | done; audit unified list and surfaced machine identity | T2 independently audits | valid |
| B098 | done; audit bus-never-RPC/approval isolation | T2 independently audits | valid; safety regression evidence mandatory |
| B099 | done; audit canonical untrusted-data framing across adapters | T2 independently audits | valid; adapter conformance evidence mandatory |
| B100 | done; audit cross-machine golden-path docs | T2 independently audits | valid |
| B101 | pending, do now; package-manager-aware self-update | likely T4 implementation | justified |
| I002 | pending, do now; lean versioned JSON v1 | likely T4 implementation | justified; must reconcile already-done B089 output |
| I003 | deferred; trust tiers/TOFU after identity work | T3 preserves decision | justified defer |
| I004 | deferred; receipts/wait need push+cursors | T3 preserves decision | justified defer; premise conflicts with B096 wording |
| I005 | pending, do now; fake relay and named regressions | likely T4 implementation | justified |
| I006 | deferred; relay discovery raises abuse surface | T3 preserves decision | justified defer |
| I007 | deferred north star; harness unification after I002/identity | T3 preserves decision | justified defer |
| I008 | decision recorded, implementation deferred; machine key is trust anchor with optional machine-signed per-agent attestation | T3 preserves decision | justified defer; must explicitly supersede the report's earlier per-agent-key recommendation |

Implementing only B101, I002, and I005 among the currently pending items is therefore justified by the recorded Max decisions. It is not a license to ignore gaps found while re-auditing B087-B100: any refuted done item must create an additional implementation slice. The report's earlier recommendation to “make keys per-agent” is superseded by Max's later I008 decision to retain the machine key as the relay trust anchor and add only optional machine-signed per-agent attestation; the final evidence matrix must record that precedence explicitly rather than presenting both as unresolved alternatives.

## Attempted decisive criticisms

### 1. Major — audit worktree bases are undefined

- Criterion failed: plan AC2 and AC5; branch-per-slice chain-base rule.
- Evidence: the plan says the audits must check current local `master` and explicitly notes the 35-commit divergence (lines 7 and 12), but T1-T3 specify only worktree paths, not bases or prerequisite SHAs (lines 30-49). B087-B100 are local-master content absent from `origin/master`.
- Decisive effect: branching canonically from `origin/master` would audit the wrong code and report false gaps; branching from local `master` without declaring the chain-slice exception violates the required base-selection contract.
- Proposed fix: declare the exact base/prerequisite for every audit and implementation slice. The three closure audits must start from a recorded local-master tip containing B087-B100; each later slice must explicitly classify itself as independent (`origin/master`) or prerequisite-bearing (local-master/prerequisite SHA).
- Status: open.

### 2. Blocker — the proposed reviewer fallback cannot satisfy peer-PASS

- Criterion failed: plan AC5/AC7 and `AGENTS.md`'s real-peer-PASS rule.
- Evidence: plan line 7 says no live peer exists and treats fresh-slate collaboration subagents as the fallback; lines 15 and 61 require only generic review/review-and-fix. `AGENTS.md` says a subagent of the author does not count and requires a real peer whose build was run in the slice worktree, with `build-clean-IN-slice-worktree-rc=0` captured.
- Decisive effect: the plan can currently synthesize code/doc slices after only self-tree/subagent review, contrary to the mandatory landing gate.
- Proposed fix: allow implementation to proceed, but make final closure block until an independent live peer reviews every changed slice and signs the current tip/range. Require clean-cache `just check`/build in the slice worktree and the verbatim build criterion; fixes get new commits and re-review.
- Status: open; currently blocking final PASS while no peer is available.

### 3. Major — live relay dogfood is optional rather than a closure gate

- Criterion failed: plan AC2, AC6, and AC7; repository rule that live-agent behavior must be tested via tmux and that work is not done until tested in the wild.
- Evidence: T1 says public-relay checks “may need network” and only asks that hermetic evidence be distinguished (line 35). Final verification requires focused tests, `just check`, and a “full relevant suite” (lines 60-63), but no public HTTPS relay run or tmux-driven real-client path is mandatory. The source failures are specifically production-relay and real-agent failures (B087-B094, B097).
- Decisive effect: the run can declare “completely addressed” from hermetic/static evidence even if current local master still fails against `https://relay.c2c.im` or a real harness.
- Proposed fix: add explicit live acceptance checks for relay-facing behavior, driven through existing `scripts/c2c_tmux.py`/repo harnesses where clients are involved, with commands, outputs, timestamps, and exit codes in evidence. Because the run policy forbids unconfirmed remote effects, persist an operator-confirmation escalation before any state-changing relay probe; if approval/live access is unavailable, final closure remains blocked rather than treating hermetic evidence as equivalent.
- Status: open.

### 4. Major — the complete inventory is deferred until final synthesis

- Criterion failed: plan AC1 and the failure criterion forbidding any unclassified report item.
- Evidence: T1-T3 are partitioned only by B087-B101 and I002-I008 (lines 30-49), while the 2,836-line source also contains product/website positioning, docs information architecture, six milestones, a full test/conformance suite, unresolved architectural decisions, and top actions. The only instruction to reconcile all headings is in the final verification step (line 62); no pre-dispatch matrix task, schema, owner, or artifact path exists.
- Decisive effect: unmapped recommendations can be discovered only after implementation dispatch, and suggestions with no B/I item can be silently omitted or dispositioned without recorded operator authority.
- Proposed fix: add a reviewed T0 inventory before T1-T4. Give every normative source item a stable row containing source line/heading, requirement, current evidence, linked backlog item or new task, disposition and authority, dependencies, required tests/docs/live proof, and closure status. Dispatch implementation only from reviewed unresolved rows.
- Status: open.

### 5. Major — nominally parallel audits contain unresolved cross-task dependencies

- Criterion failed: plan's independent-slice/dependency requirement and AC3/AC4.
- Evidence: I002 calls itself the dependency hub for B089, but B089 is audited in T1 and I002 in T3. B096 is marked done for non-destructive peek plus cursor/ack, while I004 says server-side cursors do not exist; those are split between T2 and T3. The plan has no explicit cross-audit reconciliation gate before creating T4 slices.
- Decisive effect: independently reviewed audit documents can reach mutually inconsistent closure/disposition conclusions and still feed implementation.
- Proposed fix: declare these logical dependencies and add a reviewed reconciliation stage after T1-T3, before T4 creation. It must resolve at least B089↔I002 and B096↔I004 against current code and convert the result into an ordered dependency graph.
- Status: open.

## Attempted criticisms that did not refute the plan

- The plan does not improperly force all deferred roadmap ideas into this release: AC4 and T3 preserve the recorded trusted-swarm-first decisions for I003, I004, I006, I007, and I008.
- It does not authorize push/deploy: AC8 and the safety policy keep the coordinator gate intact.
- It does not accept backlog status alone: AC2 explicitly requires behavior/test/doc evidence for B087-B100.

## Validators and evidence

- Read all 2,836 lines/headings of `/home/xertrov/src/c2c/friction-points-cn.md` and all of `outputs/plan.md`.
- Read B087-B101 and I002-I008 directly from `.backlog/`.
- Verified current refs with `git rev-parse` and `git rev-list --count origin/master..master`.
- Checked plan/run policies and the manual CORE reviewer contract.
- Checked `.collab/runbooks/git-workflow.md`, `branch-per-slice.md`, and the peer build rules in `worktree-discipline-for-subagents.md`.
- `c2c list --alive` returned no registered peers in this worktree context, confirming the plan's immediate peer-availability blocker.

## Safety and taint observations

- No destructive, remote, push, install, or deployment action was performed during review.
- The run is recorded as untainted. The source is a repository-controlled dogfood/security-friction report rather than a raw peer-message payload; final taint classification remains the coordinator's non-delegatable decision.

## Remaining uncertainty

- This was a plan review, not a code audit; the actual closure state of B087-B100 remains to be established by T1/T2.
- A live peer or operator-authorized public-relay probe may become available later, but the plan must encode those as gates rather than assume they will occur.

## Verdict

**FAIL.** The undefined bases, invalid peer-review fallback, optional live-relay verification, late/incomplete inventory, and unresolved cross-audit dependencies are decisive criticisms. Fix and re-review the plan before dispatching implementation.
