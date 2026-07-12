# Transient false-FAIL in check-broker-log-catalog.sh (nudge_tick "no source emitter")

- **Symptom**: `just check` in `.worktrees/friction-h7-status-honesty` (tip
  5c2d79b1) failed once with `❌ FAIL: 1 cataloged event(s) with no source
  emitter: nudge_tick`. Immediate direct rerun of
  `./scripts/check-broker-log-catalog.sh` in the same worktree passed
  (29 emitters / 26 cataloged / 3 allow-listed), and a full `just check`
  rerun passed rc=0. Emitter demonstrably present the whole time
  (`ocaml/relay_nudge.ml:128`, untouched by the slice).
- **Discovery**: coordinator evidence pass for slice H7, 2026-07-10 ~09:04Z,
  while a sibling worktree (friction-j5-aggregate-gate) was concurrently
  building/merging on the same shared `.git`.
- **Root cause**: NOT confirmed. The script uses plain `grep -rohP` over
  `ocaml/` (scripts/check-broker-log-catalog.sh:60), not `git grep`, so the
  known index.lock churn doesn't directly explain it. Best guess: transient
  read anomaly while a concurrent dune build (shared cache / sibling
  worktree) touched the tree, causing one file's read to miss. Not
  reproduced in 2 immediate retries.
- **Fix status**: none needed yet — treat as flaky-once. If it recurs,
  harden the script: retry the emitter scan once on mismatch before
  failing, or scan via `git ls-files -z ocaml/ | xargs -0 grep` for a
  stable file list.
- **Severity**: low (false negative in a docs gate; wastes a coordinator
  evidence-pass cycle, no correctness impact).
