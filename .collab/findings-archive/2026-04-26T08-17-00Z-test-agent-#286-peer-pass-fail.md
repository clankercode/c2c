# Finding: #286 peer-PASS FAIL — test cases defined but not registered

## Summary

Stanza's #286 (`53f09e34`) passes code review, but only 1 of the 5 new test 
functions is actually registered in the `dune runtest` suite. The other 4 are 
defined (code exists) but never added to the `run` block.

## What passes

- Implementation: clean, correct, well-commented
- Documentation (CLAUDE.md update): present
- 1 test case registered and runnable: `test_notify_shared_with_dms_listed_recipients`
- Build: `dune build` clean, `dune runtest` (relay suite) all 18 pass

## What's missing

Four test functions defined in `ocaml/test/test_c2c_mcp.ml` but NOT wired into 
the test runner:

| Test function | Covers | Status |
|---|---|---|
| `test_notify_shared_with_dms_listed_recipients` | Happy path | REGISTERED ✓ |
| `test_notify_skips_self_in_recipients` | Self-skip carve-out | DEFINED, NOT REGISTERED ✗ |
| `test_notify_skipped_when_globally_shared` | Global skip carve-out | DEFINED, NOT REGISTERED ✗ |
| `test_notify_silently_skips_unknown_alias` | Unknown alias skip | DEFINED, NOT REGISTERED ✗ |
| `test_notify_empty_shared_with_is_noop` | Empty shared_with | DEFINED, NOT REGISTERED ✗ |

## Fix

Add 4 lines to the `run` block in `ocaml/test/test_c2c_mcp.ml`, same pattern 
as the one registered case. One commit, no other changes.

## Severity

Medium — the feature works correctly but the untested carve-outs (skips-self, 
globally-shared, unknown-alias, empty-shared-with) are not validated by the 
test suite.
