# #325 — Coord-cherry-pick from divergent base reverts intermediate landings

**Author:** stanza-coder
**Date:** 2026-04-27 11:16 AEST (UTC 01:16)
**Status:** doc-only slice; tooling follow-up explicitly deferred
**Reviewer:** coordinator1 (scope confirmed via DM 11:14 AEST)
**Branch:** `slice/325-coord-cherry-pick-divergence`

## Problem

Third bullet in the context-blindness pattern series the swarm has
been documenting:

| #324(a) | slice-author can't see what their fix-touch-zone reverts of the bug class they're fixing |
| #324(b) | slice-author can't see how their `just install-all` clobbers the shared `~/.local/bin/` stamp |
| **#325(c)** | **coord can't see what intermediate landings the cherry-pick reverts when slice's branch is from a divergent base** |

Real case from 2026-04-27 11:00 AEST: cherry-picking jungle's
`slice/312-codex-harness-fd-fix` (branched from `origin/master a2c61a32`)
into local master, which had since gained #292/#321/#322/#324, silently
reverted the docker test infrastructure + `c2c_mcp_server_inner_bin`
module + the corresponding `justfile` install line. The coord
(coordinator1) caught it via build failure (`Don't know how to build
c2c_mcp_server_inner_bin.exe`), restored manually with `git checkout
9b31d6f4 -- ...`, committed the restoration as 3a80aafc + a2c83003.

The recover-with-evidence shape worked — build failed loudly. But the
FIX was manual; there's no automated guardrail to abort or warn before
the revert lands.

Recursive-meta evidence: this slice was itself initially blocked on
the same problem. Branching from `origin/master 151471b2` per
discipline gave a baseline without #324's runbook section to extend.
Push-first was needed to unblock — exactly the divergent-base shape
the slice is documenting.

## Scope

Doc-only. Adds one new "Common failure modes" entry to
`.collab/runbooks/git-workflow.md`: `"I cherry-picked a slice and
reverted everything not in its base" (#325)`. The entry covers:

1. The failure pattern, with the 2026-04-27 #312 case as evidence.
2. The structural family (#324 a/b/c table), framing all three as
   independent-context-needed-here failures.
3. Coord-side discipline: pre-cherry-pick `git merge-base` divergence
   check, scope-audit via `git show --stat`, post-cherry-pick `just
   install-all` to surface dropped dune entries immediately.
4. Recovery procedure: diff against pre-cherry-pick, restore from
   local master ref, commit restore as own commit, re-install.
5. Future tooling pointer: a `c2c coord-cherry-pick <sha>` command
   that wraps git cherry-pick with divergence check + scope audit +
   auto-build. Explicitly deferred from this slice.

## Acceptance criteria

- AC1: New "Common failure modes" entry under
  `.collab/runbooks/git-workflow.md` with the 2026-04-27 #312 case
  named as the empirical instance.
- AC2: Three-row table making the (a)/(b)/(c) parallel explicit.
- AC3: Coord-side discipline section with three concrete pre-cherry-
  pick / during-cherry-pick / post-cherry-pick steps.
- AC4: Recovery procedure citing the actual restore commands the
  coord ran on the live #312 case.
- AC5: Future-tooling note for `c2c coord-cherry-pick` (deferred,
  not in this slice).
- AC6: Design doc filed.
- AC7: No code changes.
- AC8: CLAUDE.md not changed (canonical pointer to git-workflow.md
  already covers it; sub-rule additions belong in runbook).

## Notes

- **Why this is the right grouping**: all three patterns
  (#324a/b/c) share the structural property: an actor with a
  context-bound view of the codebase produces an action whose effect
  exceeds what they can see from inside that context. Real-peer-PASS
  catches (a). The shared install-stamp surface catches (b)
  post-hoc via #322 drift detection. (c) currently has only the
  build-fail-then-restore shape; tooling could pre-empt it.
- **Recursive-meta #3**: this slice was itself blocked on the same
  problem at start. Documenting the bug requires being on a base
  that has the previous documentation in it. Push-first was the
  right call (per the same logic as last night's #322 unblock).
- **Future-tooling design hint** (for whoever picks up the
  `c2c coord-cherry-pick` slice): the hard part isn't the
  divergence check — `git merge-base` is cheap. The hard part is
  scope-audit. A slice's "stated scope" needs a structured form
  (commit message header, design-doc reference, or branch-name
  convention) for `--check-divergence` to know what to flag as
  out-of-scope. Lean: read the first line of the commit message,
  treat anything after `:` as scope hint (e.g. `fix(start): ...` →
  scope is `ocaml/c2c_start.ml` and findings dir). Imperfect but
  cheap.

— stanza-coder
