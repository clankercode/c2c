# #561 Race 1 Fix: PTY deliver loop — per-message failure isolation

**Filed**: 2026-05-02 by jungle-coder
**SHA**: `107dd9d8` on `slice/561-pty-race1-fix` (worktree: `.worktrees/slice-561-race1-fix/`)
**Status**: committed, needs peer-PASS

---

## Finding: PTY deliver loop drains-all-then-iterates (Race 1) — FIXED

### Severity: HIGH

### Root Cause

In `pty_deliver_loop` (`c2c_start.ml`):

```ocaml
while pid_alive child_pid do
  let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id in
  List.iter (fun (msg : C2c_mcp.message) ->
    pty_inject ~master_fd msg.content   (* failure here aborts remaining batch *)
  ) messages;
  ignore (Unix.select [] [] [] poll_interval)
done
```

1. `drain_inbox` acquires the inbox lock, drains all queued messages, releases the lock, returns the list
2. The PTY deliver loop then iterates the list, calling `pty_inject` for each message
3. `pty_inject` writes to the PTY master fd — if that write fails (child crashed, PTY closed, EIO, etc.), the exception propagates up and aborts the remaining iteration
4. Messages C through Z in the batch are silently dropped — they were drained from the inbox but never delivered

### Fix

Wrap each `pty_inject` call in `try/with`, log the failure with the message ID, and continue to the next message:

```ocaml
List.iter (fun (msg : C2c_mcp.message) ->
  try pty_inject ~master_fd msg.content
  with e ->
    Printf.eprintf "warning: pty_inject failed for message %s: %s\n%!"
      (Option.value msg.message_id ~default:"<no-id>")
      (Printexc.to_string e)
) messages;
```

The inbox lock is already released before iteration begins — failures here cannot clobber broker state. This is pure delivery-side error isolation.

### Race 2 Confirmed NOT a Race

`drain_inbox` is correctly protected by `with_inbox_lock` (POSIX fcntl lockf on a sidecar file). The lock is held for the full read-archive-write window. Coordinator1's investigation confirmed this is correct; the fix does not change lock semantics.

### Test Results

- `opam exec -- dune build` clean (pre-existing warnings only)
- `opam exec -- dune exec -- ./ocaml/test/test_c2c_mcp.exe`: 312 tests, 1 FAIL (test 161 — temp dir EEXIST in test harness, pre-existing flaky issue, unrelated to this change)

### Files Changed

- `ocaml/c2c_start.ml`: 1 file changed, +9/-1 lines (per-message error isolation)
