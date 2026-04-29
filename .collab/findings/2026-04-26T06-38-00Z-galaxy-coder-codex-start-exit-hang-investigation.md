# codex c2c start exit-hang investigation

**Date**: 2026-04-26
**Filed by**: galaxy-coder
**Status**: Open — needs live repro or deeper debugging session

---

## Bug Summary

`c2c start codex` hangs on exit (inner codex process has exited but `c2c start` does not return). ctrl+C out of the hang yields exit code 122.

## Symptoms

- Inner codex process exits (log shows `inner exited code=0`)
- `c2c start` parent does not return to shell
- ctrl+C while hung → process exits with code 122
- Happens on `c2c start codex` (not opencode, claude, kimi)

## Code Path Investigation

### Exit handling (c2c_start.ml lines 3657-3780)

```ocaml
let exit_code =
  if child_pid_opt = 0 then 130
  else
    (try
       let rec wait_for_child () =
         match Unix.waitpid [ Unix.WUNTRACED ] child_pid_opt with
         | _, Unix.WSIGNALED n -> 128 + n    (* e.g. 141 for SIGPIPE *)
         | _, Unix.WSTOPPED sig_n when sig_n = Sys.sigtstp -> (* SIGTSTP handling *)
         | _, Unix.WSTOPPED sig_n -> (* other stop → SIGCONT, continue waiting *)
         | _, Unix.WEXITED n -> n            (* normal exit *)
         | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
       in
       let code = wait_for_child () in
       (* ... TTY reclaim, kill inner target ... *)
       kill_inner_target Sys.sigterm child_pid_opt;
       Unix.sleepf 0.5;
       kill_inner_target Sys.sigkill child_pid_opt;
       code
     with _ -> 1)
```

### Key observations

1. **SIGCHLD setup**: Line 488 sets `Sys.signal Sys.sigchld Sys.Signal_ignore`. This means the kernel auto-reaps zombie children immediately — `waitpid` should not block waiting for an already-exited child.

2. **Exit code 122**: `128 + n` formula for `WSIGNALED n`:
   - SIGPIPE = 13 → 141 (not 122)
   - SIGINT = 2 → 130
   - SIGTERM = 15 → 143
   - 122 does NOT match the signal formula. Possible sources:
     - Raw `WEXITED 122` from codex binary itself
     - `128 + (-6)` impossible for real signals
     - Some other path in the code

3. **The `with _ -> 1` catch-all**: If any exception escapes (including EINTR that somehow slips through), exit code becomes 1. Not 122.

4. **Tee thread shutdown (lines 3708-3730)**: Only activates when `stderr_is_tty = false`. When running under tmux, stderr IS a TTY → tee is None → shutdown is a no-op. So tee is not the culprit under tmux.

5. **SIGCHLD = SIG_IGN**: The outer loop sets `Sys.signal Sys.sigchld Sys.Signal_ignore` at line 488. This means:
   - When codex exits, kernel reaps it immediately (no zombie)
   - `waitpid` returns immediately with the exit status
   - SIGCHLD is not delivered to the process

   BUT: codex itself may spawn child processes (Node.js/libuv workers). With SIGCHLD=SIG_IGN, those grand-children are also auto-reaped. This is intentional.

### Potential hang locations

1. **`wait_for_child`**: Despite SIG_IGN, could `waitpid` still block if there's some edge case with process group state? Unlikely on Linux.

2. **`kill_inner_target`** (lines 3118-3135): Sends SIGTERM/SIGKILL to the process group. If the child_pid is already dead, these are no-ops. But could they block? `Unix.kill` on a dead PID returns ESRCH ("No such process"), not blocking.

3. **`deliver_pid` reaping**: The deliver daemon (Python/OCaml process) is a sibling of the inner child, not a child. If it doesn't exit when codex exits, the outer loop won't wait for it. But the outer loop exits after the inner child, so this would only matter if deliver has its own wait loop.

4. **`start_opencode_fallback_thread`** (lines 3586-3617): This thread polls every `poll_interval_s` (default 10s). It only exits when `pid_alive child_pid_for_fallback` returns false. If `pid_alive` has a bug (false negative → process is alive but reported dead), the thread keeps running. But threads don't prevent process exit.

5. **`start_title_ticker`** (lines 3637-3638): Background thread that periodically updates terminal title. Doesn't block shutdown.

6. **`start_managed_heartbeat`** threads (lines 3650-3652): Background threads that enqueue mail. Don't block shutdown.

### Root Cause Hypothesis

Most likely: the **Ticker thread** or **heartbeat threads** have a bug where they keep the OCaml runtime alive (e.g., a blocking I/O operation or an infinite loop that prevents clean shutdown). In OCaml, threads that don't terminate don't prevent `exit()` from being called, but they may prevent final cleanup routines from running.

Alternatively: **exit code 122** is coming from codex itself (the codex binary exits 122 under certain conditions), and the hang is in the tee stderr shutdown path even under tmux, OR in the `start_stderr_tee` function.

## Missing Data

- Full output of `c2c start codex` when it hangs (logs, strace)
- Whether the hang repros without tmux
- Whether it repros with `--xml-input-fd` flag or without
- The codex version (c614860 context suggests recent codex)

## Next Steps

1. **Live repro**: Run `c2c start codex` in a tmux pane, let codex exit, observe whether `c2c start` returns
2. **Strace**: `strace -f -p <c2c-start-pid>` when hung to see where it's blocking
3. **Exit code analysis**: Confirm whether 122 comes from codex itself or from the c2c-start process
4. **Check without tmux**: See if it repros in a plain terminal

## Related Context

- This bug was filed 2026-04-23 by Max, captured by coordinator1
- Similar issue NOT reported for opencode, claude, kimi — specific to codex
- codex uses the PTY deliver daemon (needs_deliver = true) unlike opencode/claude
