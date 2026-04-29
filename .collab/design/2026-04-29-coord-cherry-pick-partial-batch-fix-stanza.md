# coord-cherry-pick partial-batch state footgun — fix design

**Author:** stanza-coder · **Date:** 2026-04-29
**Refs:** runbook §6.2 b3, finding `2026-04-29T04-20-00Z-stanza-coder-surge-coord-premature-cherry-pick.md`, `ocaml/cli/c2c_coord.ml`

## Problem

`coord-cherry-pick A..I` applies A..H, conflicts on I, prints `aborting cherry-pick` / `cherry-pick aborted`, exits 1. The "abort" is `git cherry-pick --abort` — it rolls back only the in-progress pick (I), not the 8 already-committed picks. Surge agents read "aborted" as "master untouched"; in fact master is 8 commits ahead.

## Options

### A. Atomic batch (auto-rollback)
On conflict at K, `git reset --hard <pre_batch_HEAD>` drops the K-1 applied picks.
- Pro: simplest mental model.
- Con: destructive (CLAUDE.md flags `reset --hard`); destroys *correct* partial progress (§6.3 dedup case `b563298c`); forces full re-run.

### B. Explicit partial-success report (no auto-rollback)
Same flow; honest summary on exit:
```
[coord-cherry-pick] BLOCKED at SHA: <I>
[coord-cherry-pick] master state: 8 of 9 picks LANDED, 1 conflicted, 0 pending
[coord-cherry-pick]   landed:    <A→a'> <B→b'> ... <H→h'>
[coord-cherry-pick]   conflicted: <I>  (rolled back via cherry-pick --abort)
[coord-cherry-pick]   pending:    (none)
[coord-cherry-pick] master: <pre_batch_HEAD>..<h'> (+8)
[coord-cherry-pick] to undo: git reset --hard <pre_batch_HEAD>
```
- Pro: no data loss; coord picks keep-or-rollback.
- Con: coord still acts — but that's true today; this stops hiding state.

### C. Hybrid (`--atomic` flag, default = B)
`--atomic` opts into A. Optional `--continue-after-conflict` for the dedup case.

## Recommendation: **B**; defer `--atomic` until requested

- Mid-batch conflicts are rare (~1 in 9 surge picks) but real.
- Danger is **informational**, not stateful: master ends up in a valid intermediate state, just one operators misread. Fix reporting, not state.
- Auto-`reset --hard` inside a helper inverts CLAUDE.md's "never run destructive git commands unless explicitly requested" rule.
- Partial success is sometimes correct (dedup signal); atomic semantics destroys that affordance.
- `--atomic` is unproven surface area. YAGNI.

## CLI surface

No new flags v1. Output-only:
- Replace `cherry-pick aborted` summary with the multi-line block above.
- On full success, print `master: <pre>..<final> (+N)` for symmetry.
- Exit code unchanged (1 on conflict, 0 on full).

## Implementation sketch (`c2c_coord.ml`)

1. Before the loop (~L244): capture `pre_batch_head = git rev-parse HEAD`.
2. Switch `List.for_all` → explicit recursive walk so we retain the un-attempted tail on short-circuit.
3. Failure branch (~L273–284): before `exit 1`, print the summary using `landed_pairs`, `blocked_sha`, the pending tail, and `pre_batch_head`. Include `to undo`.
4. Keep `git_abort` for the in-progress pick. Do **not** add `git reset --hard`.
5. Success branch (~L322): print `master: <pre>..<HEAD> (+N)`.

## Test approach

- Throwaway fixture repo: base `B`; branch with `X1` (clean), `X2` (clean), `X3` (conflicts).
- Run `coord-cherry-pick X1 X2 X3` with `C2C_REPO_ROOT` pointed at it.
- Assert: stdout contains `2 of 3 picks LANDED`, lists `X1→…`/`X2→…` landed, `X3` conflicted; exit 1; `git log` shows +2; tree clean.
- Golden-file snapshot the summary block to lock format.
- Reuse `C2C_COORD_DM_FIXTURE` for hermeticity.

## Acceptance criteria

1. Conflict prints `M of N picks LANDED`, landed `(orig→new)` pairs, conflicted SHA, pending SHAs, `to undo` hint.
2. Exit 1 on any conflict, 0 on full success.
3. Master is **not** auto-reset; partial state preserved + reported.
4. Existing tests pass; new partial-batch test covers the path.
5. Runbook §6.2 b3 updated to the new output format.

## Needs Max/Cairn input

1. **Confirm B over A.** Cairn's §6.2 wrote "EITHER roll back…OR explicitly report" — I read the OR as operator-choice and recommend report-only as default.
2. **`--atomic` deferral.** Ship v1 without it?
3. **Format.** Human multi-line vs JSON for tooling-grep — keep human unless coord scripts want to parse.
