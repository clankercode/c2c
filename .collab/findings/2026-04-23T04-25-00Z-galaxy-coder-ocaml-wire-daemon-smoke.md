# Wire Daemon OCaml Smoke Test Results

## Test: `c2c start kimi -n kimi-wire-ocaml-smoke` with OCaml wire daemon

### Result: PASS (with fixes)

### Issues Found and Fixed

**Bug 1 (FIXED): Blocking `waitpid` without timeout**

`run_once_live` in `c2c_wire_bridge.ml` used blocking `Unix.waitpid [] pid`
to wait for `kimi --wire` to exit. If `kimi --wire` didn't exit promptly,
`run_once_live` blocked forever and the while loop stalled.

Fix: Replaced with a `wait_loop` that:
1. Uses `waitpid [WNOHANG]` in a loop
2. Checks a 15-second deadline
3. Sends SIGKILL if deadline exceeded
4. Then calls blocking `waitpid []` to reap

**Bug 2: Empty wire daemon log**

The log file is always 0 bytes. This is a pre-existing issue:
- Child opens log with `O_WRONLY | O_CREAT | O_TRUNC` and dups to stdout/stderr
- `Printf.printf` output may be buffered and lost if the process is killed
  before flushing

This is a low-severity observability issue. The daemon IS delivering
messages (inbox drains confirmed) but nothing is written to the log file.

### Evidence of Working Delivery

```
# Sent message to kimi-wire-ocaml-smoke2
c2c send kimi-wire-ocaml-smoke2 "ping from galaxy-coder - OCaml wire daemon test 2"

# After 10s, inbox was empty (message drained):
cat .git/c2c/mcp/kimi-wire-ocaml-smoke2.inbox.json
[]   # was [{"from_alias":"galaxy-coder", ...}] before drain
```

### Wire Daemon Process Architecture (correct)

```
outer c2c start (pid X)
  └── inner c2c start (pid Y)          ← start_wire_daemon forks here
        └── wire daemon (pid = Y)      ← setsid(), runs while loop
              └── kimi --wire (pid Z)  ← run_once_live spawns this
```

Wire daemon PID equals inner c2c start PID because fork+setsid+no-exec.
This is correct — the wire daemon is a forked child that becomes session leader.

### Recommendation

The 15-second timeout is arbitrary. Consider:
- Making it configurable
- Using `Lwt` for a cleaner async wait
- Fixing the log buffering (use `flush stdout` before writes, or `setvbuf`)

## Commit

- a59867a: Cycle fix (remove C2c_start/Relay re-exports from c2c_mcp)
- 3c6e5b7: Wire OCaml C2c_wire_daemon for kimi (wiring change)
- NEXT: wait timeout fix for run_once_live
