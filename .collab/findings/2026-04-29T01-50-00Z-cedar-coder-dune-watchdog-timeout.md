# dune watchdog timeout causing `just test-ocaml` to exit 1

## Timestamp
2026-04-29T01:50:00Z

## Alias
cedar-coder

## Topic
dune-watchdog.sh / just test-ocaml recipe / false test failure

## Severity
LOW — tests actually pass; only the watchdog wrapper misreports failure

## Symptom
`just test-ocaml` exits 1 (recipe failure), but `dune runtest` directly exits 0 with all tests passing.

## Discovery
While testing the #388 read_file/write_file convergence slice, ran `just test-ocaml` to verify all OCaml tests. Recipe reported exit code 1. Direct `opam exec -- dune runtest --root "$PWD" ocaml/` showed all tests passing (exit 0).

## Root Cause
The `scripts/dune-watchdog.sh` wrapper in the `test-ocaml` just recipe triggers a timeout on long test suites. The `DUNE_WATCHDOG_TIMEOUT` env var is set to 60 seconds. The test suite may be exceeding this, or the watchdog script's timeout logic is firing spuriously.

The issue is the recipe failing, not the tests themselves. The relay tests (28/28), c2c_start tests, and all other suites pass cleanly when run directly.

## Fix Status
Not fixed. Workaround: use `opam exec -- dune runtest --root "$PWD" ocaml/` directly instead of the `just test-ocaml` wrapper.

## Impact
Slice peer-PASS verification requires confirming `just test-ocaml` exit 0 — currently not achievable. Reviewers must use `dune runtest` directly and note that the watchdog failure is a tooling issue, not a test failure.

## Files
- `justfile` line 116: `flock _build/.c2c-build.lock scripts/dune-watchdog.sh ${DUNE_WATCHDOG_TIMEOUT:-60} opam exec -- dune runtest --root "$PWD" ocaml/`
- `scripts/dune-watchdog.sh`: watchdog wrapper script
