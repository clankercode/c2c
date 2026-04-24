# #113 managed Codex exit hang — analysis

**Author**: galaxy-coder  
**Date**: 2026-04-24T09:12 UTC  
**Status**: Analysis complete — fix requires Max (c2c_start.ml off-limits per AGENTS.md)

## Bug

`c2c start codex` hangs on exit after inner process exits. `ctrl+C` → exit code 122. Outer loop never returns.

## Findings

### Suspected hang point

`Thread.join tee_thread` at `c2c_start.ml:2334`.

### Tee thread lifecycle

- Created at line 515, runs until `stop_read_fd` or `pipe_read_fd` signals exit
- Reads child's stderr via `Unix.select [pipe_read_fd; stop_read_fd]` (line 573)
- When data on `pipe_read_fd`: reads, buffers, flushes lines to `outer_stderr_fd` and `stderr.log`
- When data on `stop_read_fd`: raises `Exit`

### Cleanup sequence (lines 2325-2335)

```ocaml
(* Close tee pipe write-end → EOF to pipe reader *)
Unix.close tee_write_fd;  
(* Signal stop pipe → interrupts select *)
ignore (Unix.write_substring tee_stop_fd "x" 0 1);
(* Thread.join → HANG HERE *)
Thread.join tee_thread;
```

### Root cause hypothesis

After Codex exits, grandchildren may still hold copies of the stderr pipe write end (inherited across fork+exec). When `tee_write_fd` is closed, only Codex's copy is closed — grandchild copies remain open. Result: `pipe_read_fd` never reaches EOF, `Unix.read` blocks forever in the tee thread, `Thread.join` deadlocks.

The stop pipe signal SHOULD interrupt the select, but:
1. The write to `tee_stop_fd` is only 1 byte
2. If the select is woken by the pipe data before the stop signal arrives, it reads data (blocking read), then loops back to select — which could be after the stop signal was already consumed
3. The stop signal is a one-shot; if the thread is deep in `Unix.read` (not select), the signal is lost

### Exit code 122

`128 + 122 = 250` — no standard Linux signal maps to this. Exit code 122 is likely an explicit `exit(122)` call, not a signal. Source unknown. Separate issue from the hang.

## Fix candidates (for Max)

1. **Timeout-based thread join**: Wrap `Thread.join` in a wrapper thread with a 2s timeout. If thread doesn't exit, detach and continue. OCaml doesn't have native timed join.

2. **Non-blocking pipe close**: Before joining, set `pipe_read_fd` to non-blocking mode. If `Unix.read` would block, drain whatever is available then exit.

3. **Double-stop-pipe write**: Write 2 bytes to `tee_stop_fd` to ensure the signal is not lost in a race with data arrival.

4. **setsid before execve**: Put the child in its own session so grandchildren don't inherit pipe fds. But this is fragile and may break Codex's own process management.

## Recommended fix

Option 1 (timeout join) — most robust. Example approach:
- Create a watchdog thread that sleeps 2s then writes to a pipe the tee thread monitors
- Main thread does `Thread.join` with the watchdog
- If watchdog exits first → tee thread is stuck → detach tee thread and continue

Note: OCaml's `Thread.join` blocks indefinitely. A common pattern is to create a thread just for joining:
```ocaml
let join_with_timeout th timeout_s =
  let timed_out = ref true in
  let watchdog = Thread.create (fun () ->
    Thread.delay timeout_s;
    if !timed_out then (* signal stuck *)
  ) in
  Thread.join th;
  timed_out := false;
  Thread.join watchdog
```

## Correction (galaxy-coder, 2026-04-24T09:20 UTC)

jungle-coder's draft fix at `fa986c7` (worktree `.worktrees/113-tee-join-timeout/`) was **FAKE**. lyra-quill correctly identified the flaw.

### Why the fix is broken

The implementation:
```ocaml
let timed_tee_join th =
  let watchdog () =
    Thread.delay timeout;
    Printf.eprintf "[c2c-start] tee thread join timed out after %.1fs — detaching\n%!" timeout
  in
  let w = Thread.create watchdog () in
  (try Thread.join th with exn -> ...);  (* BLOCKS FIRST *)
  Thread.join w
```

`Thread.join th` is called UNCONDITIONALLY before the watchdog can do anything. The watchdog only runs after the join completes (success or exception). So if `Thread.join th` hangs forever, the watchdog never fires.

### The correct approach

Need to race the join AND watchdog simultaneously:

```ocaml
let timed_tee_join th =
  let timed_out = ref true in
  let watchdog () =
    Thread.delay (tee_join_timeout_s ());
    if !timed_out then (
      Printf.eprintf "[c2c-start] tee thread timed out — detaching\n%!";
      Thread.detach th
    )
  in
  let w = Thread.create watchdog () in
  Thread.join th;
  timed_out := false;
  Thread.join w
```

But even this has issues: `Thread.detach` in OCaml 5+ frees the thread's stack but CANNOT interrupt a blocking syscall like `Unix.read`. The read will return EINTR or block forever in the kernel. Detaching a stuck thread doesn't unblock the syscall.

### True fix options

1. **Non-blocking pipe reads**: Make the pipe non-blocking. On EAGAIN, exit. Requires OCaml's Unix library to support non-blocking mode on pipe fds.

2. **Signal-based interrupt**: Unix signals can interrupt select() but NOT a blocking read() once it's inside the kernel. So the stop-pipe approach works for select but not for read.

3. **Close the fd from another thread**: Unix.close on the pipe_read_fd from the main thread WOULD cause the blocked read to return with an error. This is the most reliable approach — but OCaml's Unix.close is not signal-safe.

4. **Use eventfd or a self-pipe instead of a pipe**: eventfd can be written to from another thread and the read would return immediately with the counter.

The cleanest real fix: instead of trying to join the tee thread, just detach it and close the pipe fds from the main thread. The thread will exit when the pipe is closed (read returns with error, thread exits via the Exit exception path). No join needed.

### Third review finding (lyra-quill, 2026-04-24T09:25 UTC)

Even the corrected patch (fa986c7, then 0bcead6) still has the watchdog stall issue on fast path. `Thread.join w` at the end always waits for the watchdog's full `Thread.delay timeout` — even when the tee thread exited cleanly in milliseconds.

**Fix**: detach the watchdog instead of joining it. No `Thread.join w` at all. The watchdog either:
- Fires after timeout → detaches stuck thread
- The main thread join completes fast → watchdog will exit naturally when the process exits (detached threads are cleaned up on OCaml 5+)

### Fourth review finding (lyra-quill, 2026-04-24T09:29 UTC)

`Thread.join th` is fundamentally uninterruptible by a concurrent watchdog. The join call sits on the call stack until the thread terminates — no amount of detaching, signaling, or timing out from another thread can break it.

**Correct fix**: Close the pipe file descriptors from the main thread BEFORE joining. In Linux, closing an fd that another thread is blocking on `read()` causes the read to fail with EBADF. The tee thread catches this in its `with _ -> ()` handler and exits. Then `Thread.join` returns immediately.

Implementation:
```ocaml
(* In cleanup sequence, close pipe fds BEFORE Thread.join *)
let cleanup_tee_thread tee_thread_opt pipe_read_fd stop_read_fd =
  (* Close pipe_read_fd — forces blocked Unix.read in tee thread to fail with EBADF *)
  (try Unix.close pipe_read_fd with _ -> ());
  (* Close stop_read_fd too *)
  (try Unix.close stop_read_fd with _ -> ());
  (* Now join is guaranteed to return quickly since tee thread will exit *)
  match tee_thread_opt with
  | Some th -> Thread.join th
  | None -> ()
```

No watchdog, no timeout, no race. The fd close is the interrupt.

### Fifth finding (lyra-quill + galaxy-coder, 2026-04-24T09:29 UTC)

The key insight: the tee thread blocks in TWO places:
1. `Unix.select` on pipe_read_fd / stop_read_fd
2. `Unix.write` to `outer_stderr_fd` in `flush_line`

The stop-pipe only helps for case 1. If the thread is blocked in case 2 (writing to outer stderr), closing `tee_stop_fd` doesn't interrupt it.

**Correct fix**: close `outer_stderr_fd` FIRST, then close the pipe fds, then join. Closing `outer_stderr_fd` forces any blocked write to fail with EBADF, causing the thread to exit via its `with _ -> ()` handler. Then the pipe closes propagate, and `Thread.join` returns immediately.

Concrete shutdown sequence:
1. Close `outer_stderr_fd` ← forces tee thread's write to fail
2. Close `tee_write_fd` ← EOF on pipe  
3. Close `tee_stop_fd` and `pipe_read_fd` ← stop signal fires
4. `Thread.join` ← returns immediately since tee thread exited

No watchdog, no timeout, no Thread.join races. Simple reordering of existing close calls.
