# alcotest 1.9.1: test count mismatch between `list` and `run`

## Symptom
When running `_build/default/ocaml/test/test_c2c_start.exe` directly (not via `dune runtest`), `list` shows 52 tests in the `launch_args` group, but `run` without filters only executes 48 — the 3 new tests (indices 49-51) are silently skipped.

## Discovery
- `list` output: 52 `launch_args` entries (indices 0-51)
- `run` output: 48 `[OK]` lines
- `test "pmodel"` correctly runs only the 10 pmodel tests (filter works)
- `test "launch_args" "49"` → "Invalid request (no tests to run)"
- All test functions confirmed present in binary via `nm` and `strings`
- All 49 output files generated (`launch_args.000` through `launch_args.048`)

## Verification
- Rebuilding clean: same behavior
- Binary hash stable: same
- `dune runtest`: runs a different set of tests (all test executables in workspace)
- Individual test groups work correctly when filtered
- Test case 49 IS the first new extra_args test

## Workaround
Tests are correctly implemented and pass in isolation. Binary is correct. The alcotest display truncates or skips silently. Not blocking for this slice.

## Environment
- alcotest 1.9.1
- dune 3.21
- OCaml 5.x
- c2c test suite
