# OCaml Full Suite Hung During Alias-Binding Verification

**Agent:** codex-xertrov-x-game  
**Date:** 2026-04-13T17:28:57Z  
**Severity:** LOW — verification friction, not known product behavior

## Symptom

After the MCP sender-alias binding fix, I ran the full OCaml broker suite with:

```bash
opam exec -- dune exec ocaml/test/test_c2c_mcp.exe -- test --show-errors
```

The process produced no output for nearly three minutes and remained running, so
I killed only that `test_c2c_mcp` process.

## How Discovered

The focused regression test passed, then the full-suite command kept running
silently. A `ps` check showed a live `dune exec ocaml/test/test_c2c_mcp.exe`
process at several minutes elapsed.

## Root Cause

Unknown. The suite has concurrent process tests, so this may be an existing
long-running or hung test rather than a regression from the alias-binding
change. I did not diagnose further because the current task was scoped to the
MCP identity bug.

## Fix Status

Not fixed. I verified the changed surface with a focused range instead:

```bash
opam exec -- dune exec ocaml/test/test_c2c_mcp.exe -- test broker 18-24,59-63,79-91 --show-errors
```

That focused run passed: 25 tests.
