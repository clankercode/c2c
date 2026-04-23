# Bug: c2c start codex hangs on exit (code 122)

**Date:** 2026-04-23
**Reported by:** Max (_ingest/bugs/codex-c2c-start.txt)
**Status:** Open — needs investigation

## Symptom

```
[c2c-start/Lyra-Quill-X] inner exited code=122 after 45.0s (pid=635415)
^C  ← user had to ctrl+c to kill outer loop
```

The inner codex exited with 122, but the outer loop (c2c start) didn't exit on its own.
User had to Ctrl+C to terminate.

## Observations

- Exit 122 is from **inner codex process**, not from c2c itself
- OCaml `c2c_start.ml` should handle this: `cleanup_and_exit exit_code` at line 1804
- The `cleanup_and_exit` function (lines 1314-1338) kills inner process group, stops sidecars, removes pidfiles
- SIGTERM handler (line 1343) calls `cleanup_and_exit 0` then `exit 0`
- The Python version (`c2c_start.py`) was also running Python deliver_inbox.py

## Hypotheses

1. **Sidecar not terminating**: deliver daemon or poker may not be dying cleanly, causing outer loop to block on a live child
2. **SIGCHLD handling**: If SIGCHLD is set to SIG_IGN for the outer process (auto-reap), `cleanup_and_exit`'s wait may misbehave
3. **Process group kill gap**: `kill_inner_target` sends to `-pid` (process group) but some child processes may have reparented to PID 1 already

## Files to check

- `ocaml/c2c_start.ml:1314-1345` — cleanup_and_exit and SIGTERM handler
- `ocaml/c2c_start.ml:1290-1293` — sidecar pid refs
- `ocaml/c2c_start.ml:1772` — where inner exit is reported
- `c2c_start.py:cleanup_and_exit` (deprecated, Python version)

## Note

Max is actively editing `c2c_start.ml` and mcp delivery (as of 2026-04-24). Do NOT reset or edit those files.
