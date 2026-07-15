# `just check` full build broken on master — warnings-as-errors in 7 test files

- **When**: 2026-07-13T04:25Z (found while gating the B140 slice)
- **Who**: b140-alias-rename session (Max-driven Claude, B140 slice)
- **Severity**: HIGH — the shared pre-merge gate (`just check` → full
  `dune build`) fails for EVERY worktree, so any agent relying on it is
  blocked or (worse) starts rationalizing around a red gate.

## Symptom

`just check` fails at the `scripts/dune-build-locked.sh build` step with
Warning 10 (non-unit-statement) / Warning 8 (partial-match) promoted to
errors. Reproduced in the MAIN tree at master `cbe4122e` — NOT introduced by
the B140 slice (none of the failing files are touched by it; their last
changes are `88047c00` "fix(claude): emit non-error Stop feedback" and
`5a5ccbf0` "feat: remove Gemini client support" era).

Failing files (from `just check` log, `sort -u`):

- `ocaml/cli/test_c2c_onboarding.ml` (13 sites, W10)
- `ocaml/cli/test_c2c_setup_kimi.ml` (5 sites, W10 — `run_setup_codex ... ()`
  now returns non-unit and is used as a statement)
- `ocaml/cli/test_c2c_worktree.ml` (W8 partial match — hex-digit mapping
  missing a case, e.g. `16`)
- `ocaml/test/test_c2c_codex_session.ml` (line 89)
- `ocaml/test/test_c2c_schedule_persist.ml` (line 124)
- `ocaml/test/test_relay_e2e_integration.ml` (lines 64-65)
- `ocaml/test/test_relay_pubkey.ml` (lines 107, 127)

## Root cause (probable)

Recent slices changed signatures (e.g. `run_setup_codex` / onboarding
helpers now return a result) and validated with TARGETED builds
(`build-cli`, specific test exes) — the full `dune build` (which `just
check` runs and which builds every test target) was never re-run, so the
warning-as-error breakage accumulated silently across several slices.

## Fix status

NOT fixed in the B140 slice (out of scope — 7 files across several agents'
active areas; a drive-by would collide with in-flight work). Needs one
dedicated fix slice: add `ignore`/`let _ =` at the W10 sites, complete the
W8 match, then re-run `just check` from a clean worktree.

B140 gating evidence in lieu of `just check`: all steps of `just check`
BEFORE the full build passed (skills sync, codegen checks, git diff checks);
broker-log catalog check passes; `test_c2c_mcp` 455/455, `test_c2c_cli`
170/170, `test_c2c_changelog` 19/19 green; docs-drift clean except a
pre-existing CLAUDE.md note; E2E rename smoke green.

## Lesson

Targeted builds hide full-build breakage. If your slice changes a helper
signature used by other test files, run the FULL `dune build` (or `just
check`) before merge, not just your own test targets.
