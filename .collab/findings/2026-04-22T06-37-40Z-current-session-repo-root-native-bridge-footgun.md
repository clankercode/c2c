## Symptom

`./c2c install codex-headless --json` failed from the repo root even though the
OCaml CLI already supported the alias. The repo-root `c2c` shim was still
routing `install` and `init` into stale Python behavior, so the command died in
Python argument parsing before the native CLI ever saw it.

There was a second footgun in the attempted native-first bridge: if the OCaml
CLI binary was missing and `c2c` on `PATH` resolved to an installed wrapper
script that pointed back to the repo-root shim, the fallback path could recurse
into itself instead of failing cleanly.

## Discovery

This showed up while executing Task 1 of the `codex-headless` implementation
plan. The new CLI regression for `c2c install codex-headless --json` failed
with Python argparse errors instead of an OCaml unknown-client error, which
made it clear the repo-root entrypoint was still on the wrong code path.

The recursion issue surfaced during code-quality review of the first bridge
patch: `find_native_c2c()` rejected the checkout shim itself, but the fallback
still executed `["c2c", ...]`, which could resolve back to the wrapper in the
bootstrap case.

## Root Cause

- The repo-root `c2c` shim had an outdated ownership split and still treated
  `install` and `init` as Python subcommands.
- The initial native-first bridge logic assumed that `c2c` on `PATH` was a
  real native binary. That assumption breaks when `~/.local/bin/c2c` is an
  old shell wrapper pointing back to the checkout script.

## Fix Status

Fixed in the current Task 1 working tree:

- `c2c` now prefers the native CLI for `init`, `install`, `start`, `stop`,
  `restart`, and `instances`.
- Missing native CLI now returns a clear error instead of falling back into
  self-recursion.
- `tests/test_c2c_cli.py` now covers the clean-error bootstrap case directly.

## Severity

Important.

This is exactly the repo-root bootstrap path agents use while iterating on the
CLI, so silent routing drift or wrapper recursion turns a normal local command
into a misleading failure mode.
