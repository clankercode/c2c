# End-of-Burn Backlog Audit — 2026-04-28 05:52 UTC

**Author**: coordinator1 (Cairn-Vigil)
**Scope**: full task-tracker grooming pass after the 2026-04-28 burn window. Cross-reference: `git log --since="2026-04-28"`, `.sitreps/2026/04/28/{03,04,05,06}.md`, `todo.txt`, `todo-ongoing.txt`, `todo-ideas.txt`, `.collab/findings/2026-04-28*`, `.collab/research/2026-04-28*`, `.collab/archived-issues.txt`, `TASKS_FROM_MAX.md`.
**Method**: walk every task ID referenced in commits/sitreps/todo files; classify by status; cross-check ownership against actual recent activity. Snapshot only — no file mutations beyond this report.

---

## 1. Summary stats

| Bucket | Count |
|---|---|
| Tasks **closed today** (referenced in `git log --since="2026-04-28" --grep="^docs\|^feat\|^fix\|^test\|^role"` with shipping commit) | **~30** (see §2 below) |
| Tasks **pending** (referenced in todo-ongoing/sitreps but no closing commit yet) | **18** |
| Tasks **in_progress** (claimed in current sitrep §3 or known live worktree) | **6** |
| Tasks **filed-and-cold** (mentioned 2026-04-28 but no peer assignment) | **5** |
| Tasks **stale / superseded / closeable** (filed pre-2026-04-26, no recent reference) | **3 explicit + several implicit** |
| Total unique IDs referenced in `git log --since="2026-04-26"` | **~67** |
| Today's commits (since 2026-04-28T00:00Z) | **~50** |
| Today's sitreps (`.sitreps/2026/04/28/`) | **4** (03/04/05/06 UTC) |

**Closed today (verbatim from sitreps + commit attribution)**: #266 (memory-local-only follow-up), #310 (multi-container Docker E2E), #311 slice A (mcp-inner), #312 (codex harness fd leaks + hang), #318 (heartbeat-config thunk — partial; v3 still in flight), #320 (CLAUDE.md trim), #323 (auto-DM-on-cherry-pick — shipped + dogfooded), #326 (memory_list shared_with_me semantics), #327 (send-memory handoff DM diagnostic), #331 (MCP memory_* integration tests), #334 (project-scoped .mcp.json default + PUSHED), #335 v2a (nudge skip pidless/unknown), #336 (just build covers c2c.exe), #338 (design committed, impl pending), #339 (memory local-only docs), #340a (OpenCode install doc residuals), #346 (AUTO_DRAIN_CHANNEL default→OFF), #347 (send-memory-handoff scope clarified), #348 (low-severity drift bundle), #356–#359 (public-docs accuracy bundle), #360 (migrate-broker --help), #361 (doctor broker-root canonical), #364 (enqueue self-heal restored), #365 (sitrep_append UTC), #366 (onboarding --session-id), #367 (git shim author env respect), #369 (runbook dead-end commands), #371 (peer-pass --allow-self convention), #373 (subagent cd-discipline runbook).

That is **30 task IDs closed in a 24-hour window**, with 5 of them being multi-commit chains and #334 reaching origin/master (only push of the day).

---

## 2. Pending task disposition

For each pending #NNN, the bucket and unblocker:

### 2a. Still actionable (next-session pickable)

- **#318 (heartbeat-config thunk refactor, v3)** — galaxy-coder owns. Stanza-FAILed v2; v3 respin is the unblocker. Live worktree expected. **Actionable** — galaxy's first slice on return.
- **#330 (cross-host relay-mesh validation)** — paused only because earlier multi-container runs OOM'd. With #310 closed and the docker-compose mesh file present (`docker-compose.relay-mesh.yml` is in `git status`), this is unblocked from the OOM angle. **Actionable** — needs OOM-bounded run plan.
- **#332 (mkdir_p ENOENT for missing parent dirs in MCP path)** — test-agent claimed; no commit yet. **Actionable** — small fix, can absorb into next test-agent slice.
- **#337 (one of the post-restart cluster, surfaced from OOM recovery)** — filed but no owner. **Actionable** — needs a re-read of the filing to refresh scope.
- **#338 (shared-repo .mcp.json shape)** — design committed today (`6841efa9`); implementation phase queued for stanza per sitrep §5. **Actionable** — design is locked.
- **#341 / #342 (post-restart UX cluster — active-Monitor visibility)** — filed in 04 UTC sitrep; #342 about coord not being able to list its own running heartbeats (bit us with duplicate timer-fires today). **Actionable** — small CLI-add-only slice.
- **#344 (sweep-predicate hardening)** — queued in todo-ongoing; impl in flight per sitrep. **Actionable** — verify ownership.
- **#345 (auto_register_startup-guards)** — same cluster as #344; impl in flight; deep-dive at `.collab/research/2026-04-28T04-34-00Z-stanza-coder-auto-register-guards-deep-dive.md`. **Actionable**.
- **#350 (broker-root drift in public docs, 7 files)** — shipped at `9e15b6e1`, **awaiting peer-PASS** (test-agent queued; reviewer-side worktree-visibility gap surfaced — see §7 of 06 UTC sitrep). **Actionable** — once test-agent's reviewer subagent can see stanza's worktree.
- **#352 (doctor broker-root migration prompt)** — blocked on #360 hotfix (now LANDED for `--help`; full migration prompt still open). Investigation: `.collab/research/2026-04-28T04-44-00Z-stanza-coder-352-doctor-broker-root-investigation.md`. **Actionable** post-#360-impl.
- **#354** — research file says "absorbed into #367 commit" (`.collab/research/2026-04-28T05-54-00Z-stanza-coder-354-absorbed-into-367-commit.md`). **Should be closed quietly** — see §2d.
- **#372 (referenced in commit set but not in sitrep)** — needs scope re-read. Likely a small slice. **Actionable**, low priority.
- **`todo.txt` line 71 (DESIGN ephemeral one-shot agents — DRAFT exists)** — 7 open questions for Max. **Actionable post-Max-input** — design doc lives at `.collab/design/DRAFT-ephemeral-one-shot-agents.md`.
- **`todo.txt` line 73 (IDEA task-decomposition + planning agent)** — endorsed; depends on ephemeral-agents infra. **Blocked on prior**.
- **`todo.txt` line 75 (IDEA standby reviewer agents)** — endorsed by Max; pairs with peer-review-before-coordinator-review convention. **Blocked on ephemeral-agents infra**.
- **`todo.txt` line 84 (sender permissions / role attribute on c2c xml)** — design partial per `.collab/design/SPEC-sender-role-attribute.md` (PARTIAL). **Actionable** — small envelope-attr addition.

### 2b. Newly surfaced (filed during the burn, not yet picked up)

These are this hour's findings; treat as fresh pending:

- **Rooms-audit H1/H2/H3** (filed 05:50 UTC by stanza, `.collab/research/2026-04-28T05-50-00Z-stanza-coder-rooms-audit.md`) — three HIGH-severity ACL gaps in invite-only rooms: `room_history` no membership gate, `list_rooms` leaks invite-only room existence + members + session_ids + invited_members, `delete_room` no caller-auth check at all. Suggested as a single small worktree on the social-layer critical path. **Highest unbumped priority** — see §5.
- **Peer-pass security audit** (filed 05:34 UTC by stanza, `.collab/research/2026-04-28T05-34-30Z-stanza-coder-peer-pass-security-audit.md`) — A=2 high (artifact carries its own pubkey, `allowed_signers` not consulted by verify), B=3 med, C=2 low. **Actionable** but Max's calibration (#371) explicitly deprioritized the crypto-sealing path; revisit when sealing infra returns.
- **Dead-letter audit** (`.collab/research/2026-04-28T05-34-00Z`) — A=1 high (unbounded growth / no GC), B=2 med. **Actionable** — small GC slice.
- **Broker-log retention audit** (`.collab/research/2026-04-28T05-50-30Z`) — needs read; likely retention/rotation slice.
- **Parallel-dune softlock** (`.collab/research/2026-04-28T05-20-00Z`) — captured as cross-cutting in 06 sitrep §7. **Document-only, no code slice** — heuristic added to the sitrep lessons.
- **Findings-archive sweep plan** (`.collab/research/2026-04-28T04-30-00Z`) — coordinator's own backlog item. **Actionable** during a slow hour.

### 2c. Stale / out-of-date

- **#8** — referenced in `git log --since="2026-04-26"`. Old enough that the ID likely refers to legacy numbering. **Likely stale** — ignore unless re-cited.
- **`todo.txt` line 71 (ephemeral one-shot agents DESIGN)** — design has been OPEN with 7 questions for Max for **5 days**. Either we get answers or we close as out-of-scope-for-now. Status: **needs Max ping** to refresh.

### 2d. Should be closed quietly

- **#354** — research file says "absorbed into #367 commit". **Close**: add to `.collab/archived-issues.txt` next batch.
- **#362** — closed per 05 UTC sitrep (`#335/#336/#346/#362 closed`) but no commit attribution found. **Close** — verify against archived-issues then archive.
- **#263 (`c2c start --agent X -n Y` writes Y.md but loads X agentfile)** — already in archived-issues (line 77). Mentioned for completeness; nothing to do.
- **`todo.txt` archived rotation** — most `[x]` lines from before 2026-04-23 should be pruned per the file's own hygiene rule ("more than a week old"); save for git history. **Actionable docs hygiene** during a slow hour.

---

## 3. In-progress audit

Per 06 UTC sitrep §3 + actual commit attribution since 03 UTC sitrep:

| Task | Owner | Actually moving? | Evidence |
|---|---|---|---|
| #338 design → impl | stanza-coder | **Yes** — design committed `6841efa9`; impl phase queued | Sitrep §5 explicit handoff |
| #318 v3 | galaxy-coder | **Idle on this branch** — no v3 commits today; 06 UTC §3 lists galaxy as "no in-flight assignment" | Sitrep §3 contradiction with todo-ongoing — todo-ongoing claims galaxy on v3 but galaxy-coder is idle. **Re-task or confirm.** |
| #344 / #345 | stanza-coder (impl in flight per todo-ongoing) | **Maybe** — research files exist (`2026-04-28T04-34-00Z-stanza-coder-auto-register-guards-deep-dive.md`) but no impl commits today | Stanza was busy on #335 v2a + audits; #344/#345 likely deferred |
| #332 | test-agent | **Stalled** — no commit; test-agent's window was #350 review + #336 build fix | Re-confirm |
| #350 peer-PASS | test-agent | **Active** but blocked on worktree-visibility gap (sitrep §4) | Filed for follow-up |
| #360 full impl (post-help slice) | unassigned | **Stalled** — only `--help` doc landed (`c5c5e0b6`); full migration-prompt slice still queued | Per sitrep, **plan-A galaxy-after-#318-v3, plan-C coord-direct fallback** |

**Flagged "in_progress but actually idle"**:

1. **#318 v3 / galaxy-coder** — todo-ongoing claims active, sitrep §3 says idle. Reconcile in next sitrep.
2. **#332 / test-agent** — claimed in MCP-cluster but no current evidence of work.
3. **#344 / #345 / stanza-coder** — research filed; impl not visible. Stanza pivoted to audits.

---

## 4. todo.txt & todo-ideas.txt status

### todo.txt (87 lines)

The `[ ]` open lines are:

- **Line 71** — DESIGN ephemeral one-shot agents (DRAFT). 7 open questions for Max. **Stale** — needs ping. Cited as gating #143-style scope and the planning-agent + standby-reviewer ideas.
- **Line 73** — IDEA task-decomposition + planning agent. Endorsed by Max. Blocked on ephemeral-agents.
- **Line 75** — IDEA standby reviewer agents. Endorsed by Max. Blocked on ephemeral-agents.
- **Line 84** — `c2c xml` sender permissions / role attribute. **Actionable** — small slice.

The remaining `[x]` lines older than 2026-04-23 are candidates for pruning per the file's own hygiene rule. Recommendation: a single 5-minute slice during a quiet hour to delete `[x]` entries older than 7 days. Git history preserves them.

### todo-ongoing.txt (131 lines)

Healthy and recently refreshed (`599fbf51`). Eight projects are tracked; statuses match reality except for the **#318/#344/#345 in-flight/idle reconciliation** noted in §3. Recommend coordinator updates this file during the next sitrep to flag galaxy as **idle** and explicitly route #318 v3 OR re-task galaxy.

### todo-ideas.txt (102 lines)

Three idea entries:

1. **Remote relay transport** — already `ingested` (now in todo-ongoing as a v1-shipped project; #330 paused).
2. **c2c git proxy extensions — signing + attribution** — already `ingested` (#119/#129 etc, design doc landed).
3. **PoW-gated email proxy for agent commit attribution** — `brainstorming and planning`. **Locked design today** (`43ec9b7a`): hashcash dynamic difficulty + bounceback + per-alias routing + profile link. Immediate slice (git attribution config) shipped. Future slice (PoW proxy itself) needs **promotion to `ingested`** with a corresponding entry under `todo-ongoing.txt` **once a project folder exists**, OR keep here until someone picks up the proxy build. Recommendation: **promote to ingested + add a stub entry under `todo-ongoing.txt`** so the design doesn't drift.

The "Idea: " stub at line 100 is empty and should be deleted (housekeeping).

---

## 5. Top 5 next-session priorities

Ranked by leverage (impact × unblocked × low-risk):

### #1 — Rooms ACL hardening (H1+H2+H3, stanza's 05:50 UTC audit)

**Why**: rooms are on the **north-star group-goal critical path** — the social layer / N:N topology is one of the four delivery surfaces, and `swarm-lounge` is the canonical persistent social channel. Three HIGH-severity gaps in one subsystem on a load-bearing trust foundation is exactly the shape of bug that bites once the swarm scales. Stanza's audit even includes a suggested single-worktree fix shape for H1+H2 (membership gate + visibility filter for invite-only rooms). H3 (`delete_room` no caller-auth) is a one-line guard. Mirrors the peer-pass H1/H2 pattern (advisory-not-enforced).

**Unblocker**: read the audit doc at `.collab/research/2026-04-28T05-50-00Z-stanza-coder-rooms-audit.md`; sliced as a single small worktree; `c2c_mcp.ml:4948-4969` (room_history), `:2755-2775` + `:3082-3096` (list_rooms), `:4872-4883` + `:2439-2457` (delete_room). Coverage via the existing MCP integration test suite (#331).

**Owner suggestion**: stanza-coder (already paged in on the code path); peer-PASS by jungle-coder.

---

### #2 — #360 full-impl (migrate-broker silent-data-loss hotfix)

**Why**: marked URGENT in sitrep; only `--help` doc landed (`c5c5e0b6`). The actual two-phase + fail-loud impl is still queued. **Blocks #352** (doctor migration prompt) and the broker-by-broker rollout. Stanza's finding doc is near-spec.

**Unblocker**: read `.collab/research/2026-04-28T04-50-00Z-stanza-coder-migrate-broker-silent-data-loss.md`. Plan-A: galaxy-after-#318-v3. Plan-C: coord-direct (Max-sanctioned 2026-04-28).

**Owner suggestion**: galaxy-coder once #318 v3 lands; otherwise coord-direct.

---

### #3 — #318 v3 land OR re-task galaxy

**Why**: galaxy-coder is the only currently-idle implementer per 06 UTC sitrep §3. todo-ongoing claims them on #318 v3 but no commits today. Either v3 ships or galaxy gets re-tasked to #360 / #344 / #345 / rooms-ACL. Either way the **idle implementer is the swarm's largest available bandwidth**, so this needs a coordinator decision in the next sitrep.

**Unblocker**: coord-direct DM to galaxy + decision in the next sitrep about what they're picking up.

**Owner suggestion**: coordinator1 to make the call; galaxy-coder to execute.

---

### #4 — Post-restart UX cluster close-out: #337 + #341 + #342

**Why**: the OOM-recovery pass on 2026-04-28 surfaced this cluster. #335 v2a + #346 already shipped. #337/#341/#342 are the tail. **#342 in particular** (coord can't list its own running heartbeats; bit us with duplicate timer-fires) is a coord-pain-point that we will keep re-experiencing every restart. Small CLI add-only slices.

**Unblocker**: re-read the original filings (probably in 04 UTC findings); each is likely <50 LoC. Bundle as a single sub-cluster slice so peer-PASS is one round.

**Owner suggestion**: jungle-coder (just shipped #323; warm on coord-tooling code paths) or test-agent.

---

### #5 — Public-docs peer-PASS chain close (#350 + #356–#359)

**Why**: #350 broker-root drift fix shipped at `9e15b6e1`, blocked on test-agent peer-PASS (worktree-visibility gap). #356–#359 bundle landed at `453672f0` — also needs a peer-PASS chain. These are user-trust headlines for c2c.im; **peer-PASS gating is the only thing standing between them and the next push window**.

**Unblocker**: fix the reviewer-subagent worktree-discovery gap (sitrep §7 calls this out). Either (a) document the path resolver in `.collab/runbooks/review-and-fix.md`, or (b) add a worktree-list helper the subagent can call. Then the queue clears.

**Owner suggestion**: test-agent (their own gap; they're the one blocked).

---

## 6. Cross-cutting themes

### 6a. Peer-pass calibration

Max's explicit calibration today (per #371): **substance > sealing**. Peer-PASS is a process helper, not a security gate. `--allow-self` is acceptable for mechanical/low-stakes slices. This is a **scope-easing**, not an abandonment — substantive review is still mandatory; only the cryptographic sealing has been eased while the sealing infra is parked. Stanza's peer-pass security audit (§2b) confirms the enforcement gap (verify is informational, not blocking) — that gap is now **explicitly accepted by policy** rather than a bug to fix.

**Implication for tomorrow**: stop carrying "peer-PASS sealing" as a blocker on slice landings. Reviewer's verdict + commit-trail is the substantive gate.

### 6b. Parallel-subagent dispatch — works for docs, bites OCaml

Coordinator ran 4–5 subagents in parallel today on independent doc files (#348, #356–#359, #369). Clean. The same pattern on OCaml builds **softlocked dune** (research at `.collab/research/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`).

**Heuristic going forward** (per 06 UTC sitrep): parallel-OK for read/write-disjoint docs slices; **serialize** anything that touches `_build/` or runs `just`. Worth a `CLAUDE.md` line OR a `just lock`-style guard if it bites again.

### 6c. Dogfood-loop closing

#323 (auto-DM-on-cherry-pick) was tested by **coordinator cherry-picking the #323 fixup itself and receiving the auto-DM**. That's the cleanest possible E2E validation. The pattern to generalize: **every new coord-workflow feature should be designed so its first user is the coordinator delivering it**. Already-applied this burn; document in a runbook.

### 6d. Restart-class bugs are a distinct category

The OOM-recovery pass surfaced **a class of bugs invisible during steady-state**: silent watcher drains, AUTO_DRAIN_CHANNEL eating messages, nudge floods on stale PIDs, just-build silent exit-0 hiding compile errors. The cluster (#334–#346) is now the largest single theme of the day. **Implication**: every new feature should have a "restart story" reviewer-question, on par with "test story". Already implicit in the post-restart cluster; should be made explicit in the peer-PASS rubric.

### 6e. Subagent discipline regression class

Four distinct failure modes caught this window (per 06 UTC sitrep §7):

1. `cd` out of worktree leaking shared-tree `git stash` (#373)
2. Parallel `dune` softlock (theme 6b)
3. Raw `git cherry-pick` bypassing the `c2c git` attribution shim
4. Debug-printf deletion regressing self-heal logic (#364)

All documented; **no programmatic guardrail yet**. Candidate slice: a pre-flight subagent-context preamble (a runbook the subagent must echo before its first tool call). Could be implemented as a `c2c subagent preflight` command or an injected message via `c2c install`.

### 6f. Coordinator workflow maturity

#323 auto-DM, #324 peer-PASS rubric, #325 divergent-base runbook, #334 install-path policy + push, #371 peer-PASS scope easing — together these form a **coordinator-tooling milestone**. The 06 UTC sitrep §6 restructured the goal-tree to reflect this; the work is mature enough that swarm-cycles don't need Max-direct intervention for routine cherry-picks, peer-PASS verdicts, or push decisions. **Next maturity step**: programmatic enforcement of the substance points (bug-class-recurs check, restart-story check) rather than relying on reviewer memory.

### 6g. Doc-drift bundling pattern

The day's biggest throughput came from coordinator dispatching docs slices in parallel (#348, #356–#359, #369), each as an independent subagent. **Heuristic**: doc-drift is the kind of work where parallel-subagent multiplies throughput **and** review-and-fix as same-window respin keeps the pace. The same pattern on OCaml does not work (theme 6b). **Implication**: have a "docs day" template for the coordinator to pull when stuck, with a known-clean dispatch shape.

---

## 7. Recommendations for tomorrow

1. **Promote PoW-email-proxy to `ingested`** (todo-ideas.txt → todo-ongoing.txt). The design is locked; leaving it in `todo-ideas.txt` invites drift. 5-minute coord-direct edit.

2. **Prune `[x]` entries older than 7 days from `todo.txt`**. The file's own hygiene rule says so, and the file is starting to be a slow read at 87 lines. Git history preserves the lines. 5-minute edit during a slow hour.

3. **Reconcile the #318/#344/#345 idle-vs-in-progress contradiction** between todo-ongoing.txt and 06 UTC sitrep §3. The next sitrep should explicitly state the per-task owner with a recent commit SHA OR mark "queued". Stop using `in_progress` ambiguously between "claimed" and "actively committing".

4. **Adopt the "restart-story" reviewer question** in the peer-PASS rubric (alongside "bug-class-recurs" added in #324). Every slice that touches startup, registration, watcher, hook, or daemon should answer "what does the first restart after this lands look like?". Add to `.collab/runbooks/peer-pass-rubric.md` (or wherever #324 landed).

5. **Codify the parallel-subagent heuristic** (theme 6b) in `CLAUDE.md` or a runbook: parallel-OK for docs / read-disjoint slices; serialize on `_build/` or `just`. Even a single line in CLAUDE.md saves the next coord a softlock incident.

6. **Subagent preamble** (theme 6e): consider a one-liner the subagent must produce on first turn, listing (a) its worktree path, (b) the slice ID, (c) a "I will not `cd` out of this worktree" affirmation. Catches three of the four regression modes prophylactically. Low-cost, high-leverage.

7. **Schedule a "rooms-ACL day"** as a focused single-slice burn (probably stanza + jungle peer-PASS). The audit findings are exactly the shape that gets harder to fix once we have public/external swarm members. Better to ship the gates now while the swarm is still all-trusted.

8. **Refresh stale Max-input items** (todo.txt lines 71/73/75): a single message to Max collecting all three open ephemeral-agent design questions. Avoids item-by-item ping-pong.

9. **Findings-archive sweep**: stanza filed a sweep plan (`.collab/research/2026-04-28T04-30-00Z`); the `findings/` dir is now ~35KB+ with overlap into `findings-archive/`. A coordinator-on-quiet-hour task. Improves search hit-rate for the next agent.

10. **Push cadence note**: only #334 pushed today (Max trigger). 27 commits sit on local master awaiting push verdict. The coordinator gate is holding — next coord must run `c2c doctor` and decide what (if anything) needs to be live before Max's next pull.

---

## 8. Closing observations

The 2026-04-28 burn was the largest single-day throughput in the project's history (~30 slices closed, 4 sitreps, ~50 commits, 1 push, multiple peer-PASS chains, two design docs locked, and one dogfood loop closed via meta-self-application). The discipline that made this possible — review-and-fix as throughput multiplier, parallel-subagent for docs, coordinator-as-docs-absorber — is now enough of a pattern that it deserves codification (recommendations 5, 6, 10).

The risk going forward is **coordinator-burnout**. Coord absorbed 17 of the day's commits. That's leverage when the docs queue is deep (today) and a bottleneck when it isn't. The path forward is the **standby reviewer agent** (todo.txt line 75) and the **planning agent** (line 73) — both endorsed, both blocked on the ephemeral-agents infra, which itself is blocked on Max's 7 open questions (line 71). Untangling that knot is high-leverage; recommendation 8 is the unblocker.

The north-star group goal remains: unify all agents via c2c. The four delivery surfaces (MCP auto-delivery, CLI fallback, CLI self-config, social-layer rooms) are all live; the remaining work is hardening rather than greenfield. The rooms-ACL audit (recommendation 7 / priority §5.1) is the highest-leverage hardening slice currently visible.

Quota at ~96% by reset; burn discipline holds; handoff to next coordinator-rotation hour with this audit + the 06 UTC sitrep as anchors.

— coordinator1 (Cairn-Vigil)
