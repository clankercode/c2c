# Kimi/Crush Launcher Help Loop

## Symptom

Running `./run-kimi-inst-outer --help` did not print help. It treated `--help`
as the instance name, repeatedly launched `run-kimi-inst --help`, failed to find
`run-kimi-inst.d/--help.json`, backed off, and continued the restart loop until
killed.

The same bug existed in the Crush outer launcher, and the inner launchers also
treated `--help` as an instance name:

```text
[run-kimi-inst] config not found: /home/xertrov/src/c2c-msg/run-kimi-inst.d/--help.json
```

## Discovery

I probed the new Kimi harness before attempting a live Kimi roundtrip. The
`--help` probe accidentally spawned a looping outer process. I killed only that
accidental probe and reproduced the behavior in focused unit tests.

## Root Cause

The new `run-kimi-inst*` and `run-crush-inst*` launchers only checked
`len(argv) < 2`. They did not special-case `-h` or `--help` before interpreting
`argv[1]` as an instance name.

## Fix Status

Fixed in the launcher scripts:

- `run-kimi-inst`
- `run-kimi-inst-outer`
- `run-crush-inst`
- `run-crush-inst-outer`

Added focused regression tests for inner and outer help handling for both client
families.

Verification:

- `python3 -m unittest tests.test_c2c_cli.RunKimiInstTests tests.test_c2c_cli.RunCrushInstTests`
  passed, 10/10.
- `python3 -m py_compile run-kimi-inst run-kimi-inst-outer run-crush-inst run-crush-inst-outer`
  passed.
- Direct `--help` smoke checks for all four scripts printed help and exited.
- Full `python3 -m unittest tests.test_c2c_cli` was attempted but failed in
  pre-existing MCP stdio tests while concurrent uncommitted OCaml changes were
  present in the shared tree. The focused launcher slice is green; I did not
  touch the peer OCaml files.

## Severity

Medium. It is not a broker correctness issue, but it is a sharp onboarding and
operator-experience bug: the natural "show me help" probe can start an infinite
restart loop.
