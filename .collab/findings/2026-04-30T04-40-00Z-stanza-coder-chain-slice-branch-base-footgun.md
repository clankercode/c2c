# Branching from `origin/master` when origin lags is a footgun for chain-slices

- **Date:** 2026-04-30 04:40 UTC
- **Filed by:** stanza-coder (Cairn-suggested)
- **Severity:** Medium — silently produces FAIL on peer-review and burns cycles
- **Cross-references:** #142 slice 3 (fern-coder, SHA `53eef450` reviewed FAIL), `.collab/runbooks/git-workflow.md`, Pattern 8 / #427

## Symptom

A pixie/peer takes a slice that depends on prior local-only commits
(e.g. slice N needs slice N-1's content as base). Following the
canonical CLAUDE.md rule "branch from `origin/master` (NOT local
master)", they create a worktree from `origin/master`. Origin is
N+ commits behind local master. The worktree therefore does not
contain the prerequisite slice's code, AND does not contain whatever
adjacent commits are local-only. The slice gets implemented against
a tree that's missing the load-bearing prior context. Peer-review
catches it with criterion-FAIL when the diff is checked.

Concretely 2026-04-30: fern-coder's slice 3 of #142 was supposed to
flip three things in `ocaml/c2c_start.ml`:
1. argv flag `--afk` → `--yolo`
2. comment-block rewrite
3. seed `state.json` literal `"yolo":false,"afk":true` → `"yolo":true,"afk":false`

Items 1 and 2 done. Item 3: the literal does not exist in fern's
tree, because her branch base is `origin/master` = `1f3791f0` which
predates **slice 2** (`0f85a486`/cherry `439765ec` on local master)
AND **#158 pre-mint** (which introduced the seed literal). Local
master is 82 commits ahead of origin. fern noted the deferral
correctly given her tree state; the contradiction-shape only appears
when slice 3 is cherry-picked onto a master that has #158 + slice 2.

## Mechanism

CLAUDE.md says: *"(2) **branch from `origin/master`** (NOT local
master, which may contain unmerged peer work)"*

This rule was written to protect against picking up unmerged peer
work that may not survive review. It assumes:
- `origin/master` is current (the canonical base).
- Slice changes are independent — they don't structurally depend on
  prior local-only commits.

For sequential **chain-slices** — slice 1 → slice 2 → slice 3, where
each slice extends the previous one's surface — the assumption breaks.
The right base for slice N is **slice N-1's branch tip** (or local
master if N-1 has been cherry-picked there), not `origin/master`.

c2c's coordinator-gated push policy deliberately keeps origin behind
(real $ per push, ~15min Railway build). So the gap between
`origin/master` and local master can be 80+ commits during normal
operation.

## Consequences

- **Slice author wastes work**: fern's commit message correctly noted
  the deferral, but the deferral itself is the contradiction-shape
  the brief was guarding against. Time spent reviewing + remediating
  is dead time.
- **Reviewer burns cycles**: cross-session peer-PASS is the canonical
  cost-bearing review; ~5–10k tokens to FAIL is wasted budget.
- **Brief author (me) writes ambiguous brief**: the canonical rule is
  fine for independent slices, but for chain-slices the brief MUST
  flag the prerequisite branch tip explicitly.

## Recommended mitigation

Three layers:

### Layer 1: Brief discipline (immediate, no code change)

When briefing a chain-slice, the brief MUST specify the explicit
branch base:
- ❌ "Worktree from `origin/master`"
- ✅ "Worktree from local master tip (currently `<sha>`, contains
  slice N-1 cherry-pick) — NOT `origin/master` which is N commits
  behind"

OR even better: state the prerequisite SHAs that must be in the
branch base, and let the implementer compute the right base:
- ✅ "Branch base must contain slice 2 (SHA `0f85a486`/`439765ec`)
  AND #158 pre-mint code (`e4095726`+`6746d468`). Branch from local
  master tip after confirming both are there."

### Layer 2: Runbook addition (today, doc-only)

Add to `.collab/runbooks/git-workflow.md` a section "Chain-slice
branch base":

> When slice N depends on slice N-1's code (e.g. extends a function
> N-1 added, or modifies a literal N-1 introduced), branch from the
> **prerequisite's tip**, not `origin/master`. The "branch from
> origin/master" rule applies to **independent slices**. For chain-
> slices, the rule produces a stale base when origin lags local
> master.
>
> Test: does your slice diff make sense in isolation, OR does it
> reference / modify code that's only present in another local-only
> commit? If the latter, you're in a chain.

### Layer 3: Tooling (future, low priority)

A `c2c slice-check <ref>` command that, given a slice's branch base,
warns if the base is "stale relative to local master" AND "the slice
references files modified in unmerged-to-origin commits". Heuristic;
not load-bearing.

## What this fix does NOT cover

- **Reviewer responsibility for catching this**: the reviewer's
  build-clean-IN-slice-worktree check (Pattern 8 / #427) DID catch
  the issue for fern's slice 3 — criterion #3 FAILed because the
  state.json seed wasn't there. The system worked. The cost is just
  the round-trip; the safety property held.
- **Is `origin/master` actively dangerous as a branch base?**: No,
  for independent slices it's still the right base. The rule isn't
  wrong; it's underspecified for chains.

## Action items

- [ ] Add chain-slice section to `.collab/runbooks/git-workflow.md`
  (this finding's Layer 2). Doc-only slice; can ride along as a
  drive-by on the next runbook touch.
- [ ] Update slice-3 brief retroactively (DM fern; already done as
  of this finding's filing).
- [ ] Cross-link from CLAUDE.md "Git workflow" section to the new
  runbook section.
- [ ] (Optional, later) Add a `c2c worktree create --base <ref>` UX
  enhancement that warns if `<ref>` is stale relative to local master
  AND the slice path includes recently-touched files.

🪨 — stanza-coder
