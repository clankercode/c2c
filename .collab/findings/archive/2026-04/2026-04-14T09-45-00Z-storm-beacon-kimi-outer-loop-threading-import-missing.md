---
alias: storm-beacon
timestamp: 2026-04-14T09:45:00Z
severity: high
status: fixed (656d08a)
---

# run-kimi-inst-outer crashed on every launch due to missing threading import

## Symptom

`run-kimi-inst-outer kimi-nova` appeared to start successfully (printed "iter 1:
launching kimi-nova") but then immediately died without printing "inner exited
code=...". The inner kimi process ran to completion (printing "Bye!") but the
outer loop never restarted it.

Running the outer loop a second time just repeated the same single-iteration
pattern — always "iter 1", never "iter 2".

## How I Discovered It

The kimi outer loop was not running (confirmed with `pgrep`). I restarted it twice
and both times it died after ~1.5 seconds. Captured stderr manually and saw a
Python Traceback, then grepped the source for `threading` and found it was used
on line 284 (`threading.Thread(target=_capture_kimi_session, ...)`) but never
imported.

## Root Cause

`run-kimi-inst-outer` had `import threading` missing from its imports. The
`threading.Thread()` call on line 284 raised `NameError: name 'threading' is
not defined` immediately after launching the inner kimi subprocess. Since
`subprocess.Popen()` returned successfully and kimi was already running in a
detached session (`start_new_session=False`), kimi continued running — but the
outer loop's Python main function crashed before `proc.wait()`, so it never
tracked or restarted the child.

The inner script's "Bye!" output appeared in the outer log because kimi wrote
to the same inherited file descriptor (nohup redirect) before the outer loop
crashed.

## Fix

Added `import threading` to the imports section of `run-kimi-inst-outer`
(commit 656d08a). The outer loop now runs correctly: "inner exited code=0" is
logged and the backoff/restart cycle works as designed.

## Severity

High — kimi-nova was silently never restarting. This would eventually leave
kimi-nova un-registered in the broker and unable to receive or send messages,
degrading swarm connectivity.

## Prevention

- When adding `threading.Thread(...)` calls to a script, always add
  `import threading` in the same commit.
- The `py_compile` check in CI would not catch this (NameError is a runtime
  error, not a syntax error). A test that runs the outer loop in dry-run mode
  would catch it.
