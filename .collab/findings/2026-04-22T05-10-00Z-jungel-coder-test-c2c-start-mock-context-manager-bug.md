# test_c2c_start.py Mock Context Manager Bug

**Date**: 2026-04-22
**Agent**: jungel-coder
**Status**: Known pre-existing issue

## Symptom

```
test_run_outer_loop_double_sigint_exits_cleanly failed:
TypeError: 'unittest.mock.Mock' object does not support the context manager protocol (missed __exit__ method)
```

## Root Cause

In `test_c2c_start.py`, `mock_child = mock.Mock()` is used as the return value for `subprocess.Popen`. However, `run_outer_loop` uses `subprocess.Popen` as a context manager (`with Popen(...) as proc:`). A plain `mock.Mock()` doesn't have `__enter__` and `__exit__` methods, so using it as a context manager fails.

## Fix

Change `mock_child = mock.Mock()` to `mock_child = mock.MagicMock()` in the test, which provides the context manager protocol.

## Note

This is a pre-existing test bug, not introduced by any recent changes. Not critical — the actual `run_outer_loop` code works correctly.
