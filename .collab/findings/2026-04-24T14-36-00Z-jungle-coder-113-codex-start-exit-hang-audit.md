# #113 codex start exit hang — audit findings

**Date**: 2026-04-24T14:36:00Z
**Author**: jungle-coder
**Status**: Max is actively fixing this in `c2c_start.ml` — audit is read-only

## Bug description

`c2c start codex` hangs on exit; `ctrl+C` → code 122. Exit code 122 doesn't map to standard signal exits (128+signal). The hang is in the outer loop — after the inner codex process exits, `c2c start` never returns to the shell.

## Audit findings

### Root cause candidates (read-only analysis, not verified)

**1. Tee thread not terminating cleanly**

After the inner child exits, the tee thread (which reads stderr from the child via a pipe and writes to `inst_dir/stderr.log`) may not be terminating. This would cause `Thread.join` at line 1767 to hang indefinitely.

```ocaml
(* Close tee pipe write-end so the tee thread sees EOF, then join *)
(match tee_thread_opt with
 | Some th -> Thread.join th  (* HANG HERE if tee thread is stuck *)
 | None -> ());
```

The tee thread reads from `pipe_read_fd` in 4096-byte chunks. If the child process never closes its end of the pipe (e.g., grandchild processes holding the fd open), the thread blocks forever on read and `Thread.join` deadlocks.

**2. SIGCHLD/SIGTERM race in outer loop**

The SIGTERM handler at line 1343 calls `cleanup_and_exit 0` then `exit 0`. If SIGTERM arrives while `run_outer_loop` is still inside `wait_for_child()`, the SIGTERM handler runs concurrently with the wait loop. The `_ -> ()` catch-alls in the signal handler suppress most errors, but the concurrent state mutation could leave the process in a stuck state.

**3. Grandchild processes not being reaped**

After `wait_for_child()` returns, the code calls `kill_inner_target SIGTERM` then `kill_inner_target SIGKILL` to reap grandchildren (line 1755-1757). But if the child created processes in a separate process group and those processes don't respond to SIGTERM within the 0.5s sleep window, the outer loop continues while zombie great-grandchildren remain. Not a direct hang, but could leave orphans.

**4. Process group cleanup**

For codex (non-codex-headless), `setpgid 0 0` at line 1592 puts the child in its own process group. On exit, `kill_inner_target (-pid)` kills the whole process group. If any process in the group ignores SIGTERM or is stuck in an uninterruptible syscall, `kill_inner_target` returns without blocking, but the cleanup sequence continues.

## Why this affects codex specifically

The bug is reported for `codex start exit hang`, not opencode. Codex is the only client where:
- `needs_deliver = true` (deliver daemon started)
- The tee thread is active (non-TTY stderr)

OpenCode also has `needs_deliver = false`, so no deliver daemon. The tee thread behavior might differ if codex's stderr output is larger or the tee thread reads more slowly.

## Exit code 122

Exit code 122 is unusual. Standard signal exits are `128 + signal`. If the process was killed by SIGKILL (9), exit code would be 137. Exit code 122 suggests the process hit a real-time signal or a specific platform exit path. Need Max's live reproduction to confirm.

## Files in play

- `ocaml/c2c_start.ml` — MAX IS ACTIVELY EDITING THIS FILE. Off-limits.
- `ocaml/c2c_posix_stubs.c` — setpgid/tcsetpgrp bindings

## Recommendations (for Max's fix)

1. Add a timeout to `Thread.join` on the tee thread — if it doesn't join within 2s, detach and continue
2. Add more debug logging before and after each cleanup step in `cleanup_and_exit`
3. Make the grandchild SIGKILL wait longer or loop until the process is actually dead
4. Consider making the tee thread close `pipe_read_fd` immediately after the child exits, regardless of whether EOF was seen
