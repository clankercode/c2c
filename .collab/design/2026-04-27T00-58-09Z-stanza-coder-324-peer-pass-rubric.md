# #324 — Peer-PASS rubric: bug-class-recurs check + don't-install-from-divergent-worktree

**Author:** stanza-coder
**Date:** 2026-04-27 10:58 AEST (UTC 00:58)
**Status:** doc-only slice
**Reviewer:** coordinator1 (scope confirmed via DM 10:40 AEST)
**Branch:** `slice/324-peer-pass-rubric`

## Problem

Two consecutive 2026-04-26/27 cases where slices claiming to fix a
bug class introduced a new instance of the same class:

- **#311 slice A** (galaxy) refactored MCP inner/outer foundation.
  Diff silently reverted #302+#322 install-guard infrastructure from
  `justfile install-all` (cherry-pick base predated those slices).
- **#312 fd-leak fix** (jungle, in flight) introduced a double-close
  of `fd4` on the failure path — fd-recycling hazard, exactly the
  class the slice was fixing.

Plus a related case from the same window: test-agent ran
`just install-all` from her #310 worktree against the shared
`~/.local/bin/` install path, clobbering the canonical stamp with her
divergent build (which also had uncommitted debug-printfs that
surfaced separately as Max's "lots of debug logs" report). Same root
cause from two angles — peer-isolation broken in a shared install
path.

Both patterns are about **context-blindness**: the slice author shares
a session-context with the slice-base-assumption (or with their own
WIP), and can't see what they reverted, duplicated, or clobbered. The
real-peer-PASS structural property — fresh master baseline,
independent context — is what catches them.

## Scope

Doc-only, two parts:

**(a) Bug-class-recurs-in-fix check.** Extend
`.collab/runbooks/git-workflow.md` §3 (Peer-PASS before coord-PASS)
with an explicit reviewer rubric: when a slice claims to fix a bug
class, the reviewer does an explicit pass over diff hunks asking
"does this diff itself introduce a new instance of the same class?"

**(b) Don't-install-from-divergent-worktree discipline.** Add a new
"Common failure mode" section in `.collab/runbooks/git-workflow.md`
covering the symptoms, discipline (cherry-pick latest master before
install, OR run from `_build/default/...` directly), and recovery
(coord re-installs from clean main tree; #322 drift detection
surfaces the stale stamp). v1 of this slice incorrectly suggested
`C2C_INSTALL_TARGET`/`C2C_INSTALL_STAMP` as an isolation alternative;
self-review caught that those env vars only redirect the guard/stamp
scripts, not the justfile install-all recipe's hardcoded `cp` paths,
so setting them is actively harmful (canonical binary clobbered +
stamp redirected away from canonical path). Removed in v2; per-worktree
install path is a future-tooling opportunity, not currently supported.

## Acceptance criteria

- AC1: `git-workflow.md` §3 contains a paragraph naming the
  bug-class-recurs check, with the two real-case references (#311
  slice A, #312 fd-leak), framed as context-blindness not
  competence, with explicit reviewer guidance ("do an explicit pass
  over diff hunks asking 'does this diff itself introduce a new
  instance of the same class?'").
- AC2: `git-workflow.md` "Common failure modes" section gains a
  new entry "I ran `just install-all` from a feature worktree and
  clobbered everyone's stamp" (#324) with: symptoms, discipline,
  isolation alternatives, and recovery.
- AC3: Design doc filed under `.collab/design/`.
- AC4: No code changes (doc-only).
- AC5: CLAUDE.md not changed (the canonical reference to git-workflow.md
  in CLAUDE.md already covers the peer-PASS rule; sub-rule additions
  belong in the runbook). Per the docs-up-to-date discipline: the
  surface that changed IS the runbook itself; no other surface
  drifts.

## Notes

- **Why doc-only is enough**: the bug-class-recurs check is a
  reviewer-discipline addition; it's how peer-PASS *is performed*,
  not a new tool. No code surface changes. Same for
  install-from-divergent-worktree — it's an authoring discipline + a
  recovery procedure; the existing #322 drift detection is the
  enforcement layer.
- **Future tooling opportunity**: a `c2c doctor peer-pass-readiness`
  subcommand could automate bullet (b) — verify your worktree's HEAD
  is current with origin/master before `just install-all` runs. Out
  of scope for #324; could be a follow-up if the discipline alone
  isn't sufficient.

— stanza-coder
