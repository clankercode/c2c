# c2c start codex hang on exit — investigation findings

**Bug**: `c2c start codex` hangs after inner client (Codex) exits. User must Ctrl+C to recover. Exit code 122 reported.

**Affected**: Lyra-Quill-X session, 2026-04-23. Codex v0.122.0.

**Symptoms**:
- `[c2c-start/Lyra-Quill-X] inner exited code=122 after 45.0s` — inner child exits 45s after quit
- `^C` + message appears only after user Ctrl+C
- Outer loop hangs indefinitely after inner child exits

**Known fixes/related**:
- Python deliver daemon `ModuleNotFoundError: No module named 'c2c_inject'` — lazy import fix landed at commit 4239326
- The deliver daemon crash is NOT the hang cause (deliver daemon is a sidecar, not blocking outer loop)

**Investigation (galaxy-coder, 2026-04-26)**:

The outer loop (`run_outer_loop` in `c2c_start.ml`) flow after inner child exit:
1. `wait_for_child()` returns (line 3690) — inner exit captured
2. `kill_inner_target` SIGTERM then SIGKILL (lines 3701-3703) — defensive
3. `Unix.sleepf 0.5` (line 3702)
4. Tee shutdown sequence (lines 3708-3730): close outer_stderr_fd, tee_write_fd, tee_stop_fd; Thread.join tee
5. TTY restore (lines 3732-3735)
6. Print elapsed (line 3738)
7. Record death if non-zero (line 3762)
8. `finalize_outer_loop_exit` → `cleanup_and_exit` → exit

**Potential hang locations**:
1. **Tee shutdown (lines 3708-3730)**: If the tee thread is blocked on write to outer_stderr_fd and the close sequence has a race condition. The shutdown order was previously buggy (deadlock possible) but the current order (close outer_stderr_fd first) is correct.
2. **Sidecar cleanup (`stop_sidecar`)**: The deliver daemon (OCaml) spawns a Python subprocess for inbox delivery. If the Python process is blocking on stdin/pipe, SIGTERM might not kill it promptly. `stop_sidecar` polls 30x0.1s = 3s max before SIGKILL. Could be longer if the subprocess is stuck.
3. **Signal handling race**: Outer loop has SIGCHLD=SIG_IGN (line 3443 comment). When inner child exits, kernel auto-reaps it. But `wait_for_child` uses `waitpid [WUNTRACED]` which should handle this. However, if the child is already reaped, `waitpid` returns ECHILD... but that case isn't explicitly handled in the code.
4. **Heartbeat threads**: `start_managed_heartbeat` creates detached threads that loop forever calling `enqueue_heartbeat`. If the broker RPC is hanging, these threads could block. But since `cleanup_and_exit` calls `exit`, these threads would be killed.
5. **Python deliver daemon crash loop**: If the deliver daemon keeps respawning or the Python sidecar doesn't die cleanly, `stop_sidecar` could timeout.

**Exit code 122**:
- Not a standard signal (128+signal would be 130 for SIGINT, 143 for SIGTERM)
- 122 = 0x7A — possibly from OCaml runtime or inner client
- Codex itself might exit 122 in some error condition
- The 45s delay before inner exit is suspicious — suggests inner was blocked for ~1.5x the heartbeat interval before exiting

**Next steps for investigator**:
1. Add `[c2c-start/...] exiting` log entry BEFORE tee shutdown and BEFORE cleanup_and_exit to isolate which phase hangs
2. Add `[c2c-start/...] sidecar N pid=P killing` logs in cleanup_and_exit
3. Test with `c2c start codex` in a tmux session, then manually inspect what processes remain after inner exit: `ps aux | grep -E "codex|deliver|hook"` 
4. Check if the OCaml deliver daemon (`c2c-deliver-inbox`) is still running after codex exits
5. The 122 exit code may be from Codex itself — test by running Codex directly and quitting to see if it ever exits 122

**Related files**:
- `ocaml/c2c_start.ml`: `run_outer_loop` (line 3032), `cleanup_and_exit` (line 3125), `stop_sidecar` (line 3107), tee shutdown (lines 3708-3730)
- `ocaml/c2c_poker.ml`: poker start (uses `Unix.create_process_env`)
- `ocaml/tools/c2c_inbox_hook.ml`: deliver daemon implementation

**Filed**: 2026-04-23 by Max, captured by coordinator1. Provisional bug (lazy-import) fixed 4239326; exit-hang still open.
