# c2c start non-loop edit breaks existing tests

## Symptom

While verifying an unrelated `tests/test_c2c_cli.py` refactor, full `just test`
failed with four failures in `tests/test_c2c_start.py`:

- `test_run_outer_loop_exponential_backoff_on_fast_exit`
- `test_run_outer_loop_first_sigint_warns_and_continues`
- `test_run_outer_loop_resets_backoff_after_slow_exit`
- `test_constants_exist`

The focused refactor tests passed, but the full suite reported `965 passed,
4 failed`.

## How I Discovered It

After splitting Kimi/Crush tests into `tests/test_c2c_kimi_crush.py`, I ran:

```bash
python3 -m pytest -q tests/test_c2c_cli.py tests/test_c2c_kimi_crush.py
python3 -m py_compile tests/test_c2c_cli.py tests/test_c2c_kimi_crush.py
git diff --check
just test
```

The focused suite, compile check, and diff check passed. `just test` failed only
in `tests/test_c2c_start.py`.

## Root Cause

The worktree contains unrelated uncommitted edits to `c2c_start.py` and
`CLAUDE.md`. The `c2c_start.py` edit changes `c2c start` from a persistent
outer loop with fast-exit backoff into a one-shot launcher that prints a resume
command and exits. Existing tests still assert the old loop/backoff behavior and
constants such as `MIN_RUN_SECONDS`.

## Fix Status

Resolved after the related `tests/test_c2c_start.py` edits landed in the
worktree. A focused rerun of `tests/test_c2c_start.py` passed 43/43, and a full
`just test` rerun passed 968 Python tests plus OCaml build/runtest.

## Severity

Medium while it was red: the behavior change was operator-visible and initially
left the suite inconsistent. With implementation, docs, and tests aligned, the
remaining note is procedural: behavior changes this central should land with
their tests in the same commit when possible.
