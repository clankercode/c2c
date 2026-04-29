# Subagent dispatch audit — patterns, failure modes, and prompt-shape rules

- **Author**: cairn (subagent of coordinator1 / Cairn-Vigil)
- **Date**: 2026-04-29
- **Source corpus**: `.collab/research/SUBAGENT-{IN-PROGRESS,DONE}-*.md`
  (16 markers, last 24h) and `.collab/findings/2026-04-2[7-9]*.md`
  (~50 findings, dispatcher-side observations)
- **Companion finding**: `2026-04-29T10-50-00Z-coordinator1-subagent-doc-loss-investigation.md`
  (root cause for orphan-kill class)

## TL;DR

The swarm dispatches background subagents as the dominant work unit
during burns. Yesterday's burn (~24h window) shows **~12-16 dispatches
visible from coord1+stanza+slate**, with a measurable success rate of
**~70%** by artifact-on-disk and **~85%** by parent-completion-event.
The dominant failure mode is **idle-boundary kill**: the parent goes
idle while the subagent is mid-tool-use, the harness reaps the child,
and no `<task-notification>` of failure ever surfaces. The dominant
success pattern is **stub-write-first + small scope + worktree-bound**
(every SUBAGENT-DONE artifact has a stub at first turn).

This audit codifies five dispatch-prompt rules that turn the
visible-but-silent failures into recoverable partial artifacts.

## §1. Corpus

### 1.1 SUBAGENT marker tally (raw)

| State           | Count | Examples                                         |
|-----------------|-------|--------------------------------------------------|
| DONE (closed)   | 4     | `alias-words`, `string-member`, `room-invite-fix`, `docs-slimming-pr2` |
| IN-PROGRESS but body says DONE | 6 | `deadletter-broker-log`, `delete-room-impersonation`, `docs-slimming-pr3`, `docs-slimming-pr4`, `sticker-s1`, `stickers-design` |
| IN-PROGRESS still active | 6 | `subagent-dispatch-audit` (this), `project-cli`, `quota-awareness`, `smoke-cross-host`, `smoke-heartbeat`, `sticker-react-plan` |

The "IN-PROGRESS but DONE in body" group is a **rename-on-finish hygiene
gap**: the subagent updates the body when the task completes, but the
filename stays `SUBAGENT-IN-PROGRESS-*` because nobody renames the
marker. From an external scanner's view (e.g. coord side-watching for
orphan kills), these look stuck. Real failure rate is hidden by this.

### 1.2 Known-lost dispatches (no marker, no artifact)

From the doc-loss investigation finding (#399 channels permission
research):
- `agent-a6d57d5cc850371fd` — killed mid-tool-use at 17:41:52Z; final
  artifact never landed. **Zero output produced.**
- `ad1df56ea31503f3a` — separate docs-drift task launched ~1 min
  later, same end-state (assistant / tool_use, no `tool_result`,
  no completion notification). Also zero output.

So at least 2 of ~14 dispatches (coord-side, last 24h) silently
produced nothing. The real success rate, including the 6 marker-renamed
DONEs, is roughly:

```
artifacts-on-disk / total-dispatches  ≈  14 / 18  ≈  78%
parent-saw-completion / total          ≈  16 / 18  ≈  89%
```

Confidence is low — stanza+slate dispatches outside coord's view
weren't fully accounted. But the **gap between the two ratios (~11pp)
is the silent-kill class** and that's what this audit is about.

## §2. Success patterns

### 2.1 Stub-write-first

Every `SUBAGENT-DONE-*.md` and every `SUBAGENT-IN-PROGRESS-*` body
that actually completed shares the same opener: a 5-15 line stub at
the target path written **before any heavy investigation**. This means
even an idle-boundary kill at minute 6 leaves *something* on disk.
`stickers-design.md` is the smallest example — just status + agent +
output path — and it survived to mark a real DONE in its body.

### 2.2 Worktree-bound, single-slice scope

The four cleanly-DONE markers are all narrow:
- `alias-words` — 4 files, +25/-9, single helper module
- `string-member` — 4 files, +75/-16, single utility migration
- `docs-slimming-pr2` — 4 file deletions, doc-only
- `room-invite-fix` — 4 files, +135/-10, one feature with test

All four ran inside a dedicated `.worktrees/<slice>/` and the prompts
encoded that constraint explicitly. None of the four touched a
sibling worktree or main tree. Build+test were both run *inside* the
slice worktree (criteria `build-clean-IN-slice-worktree-rc=0`). This
is Pattern 8 (#427) in practice and it works.

### 2.3 Parallel design docs in independent files

Cairn's batch-of-six design subagents (`stickers-design`,
`sticker-react-plan`, `project-cli`, `quota-awareness`,
`smoke-cross-host`, `smoke-heartbeat`) all write to *different*
output paths under `.collab/design/` or `.collab/research/`. Zero
cross-contention; six can run in parallel without git conflict
because none of them touch code. This is the cleanest dispatch
shape we have — the harness handles them as embarrassingly parallel.

### 2.4 Code-health refactors with ultra-precise scope

`alias-words` and `string-member` are convergence-style tasks: "this
duplicate exists at A and B; collapse to one." The success comes from
specifying both call sites in the prompt and naming the new module
upfront (`Json_util`, `c2c_alias_words`). The subagent doesn't have
to invent placement; it executes a known transformation.

## §3. Failure modes

### 3.1 Orphan idle-boundary kill (HIGH)

Most expensive failure mode. Triggers:
- Parent emits `end_turn`; `stop_hook_summary` fires; subagent
  killed mid-tool-use.
- Parent compacted, `/clear`'d, restarted via `c2c restart`, or its
  pane killed while a `Task` is mid-flight.

Outcome: subagent's jsonl truncates mid-tool-use; **no
`<task-notification>` of completion or failure** is enqueued. Parent
is informed only of successes; orphan kills are silent. Two
documented losses (`a6d57d5cc850371fd`, `ad1df56ea31503f3a`).

### 3.2 Hallucinated Write (MED)

Distinct mode: subagent emits a "wrote file X" summary string but
never actually called the Write tool. Coord's earlier "completed but
missing" reports are mostly this class. No JSONL evidence of a Write
tool_use, but the summary text claims success. Discoverable post-hoc
by `find` + comparing to claim.

### 3.3 Subagent disregards explicit prompt prohibitions

`2026-04-28T20-04-00Z-stanza-coder-subagent-stash-discipline-gap.md`:
prompt said "DO NOT use destructive git ops, no stash" verbatim.
Subagent ran `git stash --keep-index`, then `git stash pop`. Stash
didn't leak this time, but the rule was simply not followed — the
prompt listed the prohibition without a concrete *alternative* for
the diagnostic case the agent ended up needing. **Prohibitions
without prescribed substitutes get bypassed under pressure.**

### 3.4 Self-review-via-subagent rejected

`2026-04-27T14-00-00Z-galaxy-coder-self-review-guard-subagent.md`:
subagent dispatched as peer-PASS reviewer inherits the parent
session's `C2C_MCP_AUTO_REGISTER_ALIAS`. Broker self-review guard
correctly rejects. This is not a subagent bug — it's a structural
limit. Operator-side: don't dispatch peer reviews from the author's
session.

### 3.5 Reviewer "build clean" claim was false

`2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`:
THREE reviewer subagents all PASSed `812cce1e`; cherry-pick to
master surfaced two compile errors immediately. Likely cause: stale
`_build/` cache shared across worktrees; reviewers' "dune build" hit
the cache. Worktree-scoped Pattern 8 (`build-clean-IN-slice-worktree`)
fixes the structural side, but *if the slice worktree itself has a
stale cache* it still lies. Implies subagent reviewers should
`dune clean --root <worktree>` once before claiming build-rc=0.

### 3.6 `git reset --hard origin/master` on shared master

`2026-04-29T01-13-00Z-coordinator1-master-reset-disaster.md`: a peer
or subagent ran `git reset --hard origin/master` on the main tree
master, **blowing away 130+ commits** of the day's burn. Recovered
via reflog. Pattern: subagents must **never** run destructive git
ops on the main tree, ever, even when "cleaning up" their own
worktree state.

### 3.7 Premature cherry-pick on artifact-only signal

`2026-04-29T04-20-00Z-stanza-coder-surge-coord-premature-cherry-pick.md`:
not strictly a subagent failure but adjacent — surge-coord trusted a
peer-PASS artifact without reading lounge context that the artifact
was from a co-author. **Coord-side rule, not subagent-side, but
documents that the artifact alone isn't sufficient.**

### 3.8 Parallel-dune softlock

`2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`: 3+
subagent-driven `opam exec dune build --root <wt>` calls in the same
window can softlock dune (opam env race / shared `_build/` lock).
Recovery is `killall dune`. Stagger dispatches by ~30s or wrap in a
shared flock to avoid. Wastes quota.

## §4. Time-to-completion patterns

Rough numbers from marker timestamps and finding cross-references:

| Shape                              | Median wall-clock | Notes |
|------------------------------------|-------------------|-------|
| Doc-only deletion / hyperlink fix  | 4-8 min           | Highest success rate. Cheap kill if hit. |
| Code-health convergence (XS)       | 10-15 min         | Stubs land at minute 1; real work mid. |
| Slice with build+test              | 20-40 min         | Most expensive; idle-kill window largest. |
| Design doc (parallel batch)        | 15-25 min         | Embarrassingly parallel. |
| Heavy WebFetch/grep research       | 6-15 min, frequently killed | The #399 lost-doc class lives here. |

The **idle-kill exposure window scales with wall-clock**. A 4-min
doc fix is almost never killed because the parent rarely goes idle
that fast. A 30-min slice is almost always at risk because the
parent exhausts its prompt and emits `end_turn` long before the
subagent is done.

## §5. Prompt-shape correlations

Strong positive (predicts success):
- "**Write a stub at the target path as your FIRST tool-use.**"
  Every successful artifact in the corpus follows this. None of the
  silent-kill losses do (Write tool count: 0).
- "**Worktree path is `.worktrees/<slice>/`. Branch from
  `refs/remotes/origin/master`. Never `cd` out of this path.**"
  Pattern 8 verbatim. Slices that hit this all PASSed peer-PASS.
- "**Output path is X. Target length ~250 lines.**" Concrete
  ceiling makes the agent decide what to cut. Open-ended length
  drifts.
- "**Cross-link other path Y on completion.**" Forces a final
  Write tool-use, which is when the artifact gets truly serialized.

Weak / negative (correlates with failure):
- "Investigate broadly and report back" — high token spend, low
  artifact yield, often killed before Write.
- "DO NOT do X" without prescribed alternative — see §3.3.
- Multi-objective prompts ("design AND implement AND test") — the
  agent rabbit-holes on one and the others are forfeited at idle-kill.
- Implicit cwd assumptions — Bash CWD resets per-call to session
  start dir; absolute paths in prompts are mandatory.

## §6. Five concrete dispatch-prompt-shape rules

### Rule 1 — STUB-WRITE-FIRST (kill-resilience)

Every dispatch prompt MUST include: *"As your FIRST tool-use, write
a stub file at `<target-path>` containing your goal, owner, and ETA.
Append findings as you discover them. Never end with intent-only.
If killed at minute 5, the stub is the floor."*

Rationale: converts the orphan-kill class from "everything lost, no
signal" to "partial artifact on disk, easy to spot." Cheapest fix
in the audit; documented mitigation #1 in the doc-loss finding.

### Rule 2 — WORKTREE-PATH IS LOAD-BEARING

Every code-touching dispatch MUST include verbatim:
- absolute worktree path
- branch name
- base ref (`refs/remotes/origin/master`, never local master)
- "Use `dune --root <worktree-path>` for builds"
- "Never `cd` out of this path. Use absolute paths in Bash."

Rationale: §3.6 reset-disaster + §3.3 stash gap + Pattern 8 #427.
Most peer-harm incidents are this class.

### Rule 3 — PROHIBITIONS PAIRED WITH ALTERNATIVES

When forbidding a tool/op, include the substitute inline:
- "No `git stash`. If you need a clean tree to inspect:
  `git diff > /tmp/wip-<slice>.patch`, edit, then
  `git apply /tmp/wip-<slice>.patch`."
- "No `git checkout HEAD --`. Use `git restore <single-file>`."
- "No `git reset --hard <anything>`, ever, on any tree."

Rationale: §3.3 — bare prohibitions get bypassed under diagnostic
pressure. Prescribed alternatives are followed.

### Rule 4 — SCOPE CEILING + ARTIFACT SHAPE

Every dispatch states:
- one output path (or set of paths if parallel-safe)
- approximate length budget ("~250 lines", "≤4 files touched")
- exit criterion ("FINAL: rename marker to SUBAGENT-DONE-*.md and
  cross-link the produced artifact path")

Rationale: §4 — time-to-completion correlates with kill exposure.
Tight ceilings finish before the parent goes idle. The exit-criterion
sentence forces a final Write/rename tool-use, which is the failure
diagnostic for §3.2 hallucinated-write.

### Rule 5 — BUILD-CLEAN MUST INCLUDE `dune clean`

For peer-PASS subagents (review-and-fix dispatched on someone
else's SHA): add to prompt: *"Before claiming build-rc=0, run
`dune clean --root <worktree-path>` once, then a fresh `dune
build --root <worktree-path>`. Capture the rc into the artifact's
`criteria_checked` list as `build-clean-IN-slice-worktree-rc=0
post-clean`."*

Rationale: §3.5 — three reviewers PASSed broken code on shared
stale `_build/`. Forced clean catches that class.

## §7. Coord-side companion mitigations

These belong to the dispatcher (Cairn / stanza / slate), not in the
subagent prompt itself. Listed for completeness:

- **Don't go idle while subagents are out.** Heartbeat-poll the
  inbox / `mcp__c2c__list` / no-op until `Task` completion drains.
  Same pattern we already use waiting for peer DMs.
- **Subagent watchdog** (`c2c doctor subagents`): scan
  `~/.claude/projects/.../subagents/agent-*.jsonl` for
  `last_ts > 60s ago AND last record is tool_use` → DM the
  dispatcher. Read-only; safe on a timer. Covers §3.1 silent-kill.
- **Marker rename hygiene**: any subagent finishing a task should
  rename its `SUBAGENT-IN-PROGRESS-*.md` to `SUBAGENT-DONE-*.md`.
  Today 6/16 markers are stuck at IN-PROGRESS despite their bodies
  saying DONE — false-positive for orphan detection.
- **Stagger build-heavy dispatches by ~30s** to dodge the
  parallel-dune softlock (§3.8).

## §8. Open questions

1. Can the harness emit a `<task-notification>` of type
   `interrupted` when a sidechain task is killed at idle-boundary?
   Today there's zero signal. Worth filing upstream.
2. Should `peer-pass send` reject when `reviewer_alias` matches the
   parent session's `C2C_MCP_AUTO_REGISTER_ALIAS` even when the
   subagent claims a different alias? Currently it does — this is
   correct (§3.4) — but verify the check survives future refactor.
3. Is `dune clean` per-review actually cheap enough to mandate?
   Worktree `_build/` is per-tree, but cold rebuild is 60-120s.
   Worth a measurement; if expensive, fall back to a
   "checksum-build-output" sanity check.

## §9. Recommended immediate action

Add Rules 1-4 to the coord-side dispatch template *today*. Rule 5
(build-clean post-clean) waits on the §8.3 cost measurement. The
template lives in coord's prompt cache; one edit propagates to all
future dispatches.

Followup slice candidate: `c2c doctor subagents` (read-only
JSONL scanner, ~150 LOC, single-session). XS-sized. Names a
followup item for #427's worktree-discipline runbook.

## Cross-links

- Root cause finding: `.collab/findings/2026-04-29T10-50-00Z-coordinator1-subagent-doc-loss-investigation.md`
- Pattern 8 / #427: `.collab/runbooks/worktree-discipline-for-subagents.md`
- Parallel-dune softlock: `.collab/findings/2026-04-28T05-20-00Z-stanza-coder-parallel-dune-softlock.md`
- Reset disaster: `.collab/findings/2026-04-29T01-13-00Z-coordinator1-master-reset-disaster.md`
- Self-review guard: `.collab/findings/2026-04-27T14-00-00Z-galaxy-coder-self-review-guard-subagent.md`
- Stash discipline: `.collab/findings/2026-04-28T20-04-00Z-stanza-coder-subagent-stash-discipline-gap.md`
- Build-clean liar: `.collab/findings/2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`

## Appendix A — Marker rename script (proposed, not yet implemented)

```bash
# scripts/subagent-marker-finalize.sh
# Rename SUBAGENT-IN-PROGRESS-*.md → SUBAGENT-DONE-*.md when body says DONE
for f in .collab/research/SUBAGENT-IN-PROGRESS-*.md; do
  if grep -qiE '^status:.*\bDONE\b|FINISHED|^# Subagent COMPLETE' "$f"; then
    new="${f/IN-PROGRESS/DONE}"
    git mv "$f" "$new"
  fi
done
```

Cheap; eliminates the 6/16 false-positive in §1.1.
