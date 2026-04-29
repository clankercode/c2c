# Finding: `c2c_await_reply` test uses relative `./c2c.exe` path

**Date**: 2026-04-30
**Filed by**: jungle-coder
**Severity**: LOW
**Status**: Known, not blocking — stanza will fix as drive-by

## Symptom
When `c2c_await_reply` tests run via `dune runtest` from the worktree root, they fail with exit code 127 (subprocess not found):
```
Expected: `1'
Received: `127'
```
The binary exists at `_build/default/ocaml/cli/test_c2c_await_reply.exe` and runs correctly when executed from that directory, or when `c2c.exe` is on PATH.

## Root Cause
In `test_c2c_await_reply.ml`:
```ocaml
let c2c_binary = "./c2c.exe"
```
`Sys.command` runs from the CWD (project root when invoked via `dune runtest`), not from `_build/default/ocaml/cli/` where `c2c.exe` lives. The relative path `./c2c.exe` resolves to `$(pwd)/c2c.exe` which doesn't exist.

## Fix
Replace with an absolute path derived from `Sys.argv.(0)`:
```ocaml
let c2c_binary =
  Filename.concat (Filename.dirname Sys.argv.(0)) "c2c.exe"
```
This resolves to the actual binary's directory regardless of CWD.

## Scope
Only affects the `c2c_await_reply` test suite. Does not affect runtime behavior of `c2c await-reply` CLI.
