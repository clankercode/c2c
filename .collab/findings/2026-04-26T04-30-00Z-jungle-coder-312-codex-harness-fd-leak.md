# #312: Codex Harness FD Leak / Hang — Findings

**Author:** jungle-coder
**Started:** 2026-04-26
**Status:** Fix committed (2ec67689), peer review in progress

## Summary

`c2c start codex` can hang on exit/restart due to file descriptor leaks in
error paths and the sidecar stop sequence. The hang is intermittent and
difficult to reproduce predictably because it depends on timing of pipe buffer
drain, SIGCHLD delivery, and whether the xml fd is part of a leaking fd set.

---

## Finding 1: Duplicate `fds_to_close` and `close_unlisted_fds` definitions

**File:** `ocaml/c2c_start.ml`
**Lines:** 13–40 and 87–116

Two identical copies of both functions exist. Both handle EINTR by returning
`[]` and propagate all other errors. The duplicates compile to dead code
in the module's `.cmi` but do not affect runtime behavior. OCaml's value
restriction prevents direct unsafe use of these as shared helpers.

**Fix:** Delete lines 87–116 (the second copy). Add a comment referencing the
single canonical definition at lines 13–40.

---

## Finding 2: `request_events_fifo_opt` and `request_responses_fifo_opt` leaked if `start_deliver_daemon` returns `None`

**File:** `ocaml/c2c_start.ml`
**Lines:** 3411–3423, 3697–3715, 3771–3775

```ocaml
(* Created unconditionally when permission_sideband_enabled = true *)
let request_events_fifo_opt = if permission_sideband_enabled then
  let path = bridge_events_fifo_path name in
  ensure_fifo path; Some path
else None
in
let request_responses_fifo_opt = ...
in
```

These fifos are passed to the deliver daemon (via `event_fifo_path` and
`response_fifo_path`), but when `start_deliver_daemon` returns `None` (lines
3702–3714), the fifos are **not closed** before the code falls through.
They remain as open fds in the outer loop process.

On the next iteration or during cleanup, these leaked fds:
- Prevent the named pipes from being unlinked (kernel holds reference)
- Are inherited by any future child processes
- Could cause `EBUSY` if something else tries to open the fifo path

The `close_unlisted_fds` call in the **deliver daemon** (which runs as a
sibling, not child) closes only its own fds, not the outer's leaked fifos.

**Fix:** Add explicit cleanup of the fifos in the `None` branch:

```ocaml
| None ->
    (* Clean up leaked fifos if deliver daemon failed to start *)
    (match request_events_fifo_opt with Some p -> Unix.unlink p | None -> ());
    (match request_responses_fifo_opt with Some p -> Unix.unlink p | None -> ());
    ...
```

Alternatively, wrap fifo creation in an RAII-style helper that tracks open
fds and closes them on error.

---

## Finding 3: `codex_xml_pipe` read end leaked if `start_deliver_daemon` returns `None` in the fallback path

**File:** `ocaml/c2c_start.ml`
**Lines:** 3591–3593, 3621–3627, 3702–3714, 3716–3718, 3771–3775

```ocaml
let codex_xml_pipe =
  if client = "codex" && List.mem "--xml-input-fd" launch_args then
    Some (Unix.pipe ~cloexec:false ())
  else None
in
```

The read end of this pipe (`_read_fd`) is passed to the inner codex process
as fd 3 (line 3623). The write end (`write_fd`) is duped to fd 4 and passed
to the deliver daemon (line 3679).

After fork, in the parent (outer loop), both ends are closed at lines
3716–3718 and 3771–3775:

```ocaml
match codex_xml_pipe with
| Some (read_fd, write_fd) ->
    (try Unix.close read_fd with _ -> ());
    (try Unix.close write_fd with _ -> ())
| None -> ()
```

**However**, if `start_deliver_daemon` returns `None` in the fallback path
(lines 3708–3714), the code at 3716–3718 still runs — BUT the xml pipe was
already partially handled at lines 3702–3707 (first call) before the fallback.
The second `start_deliver_daemon` call at line 3709 uses `~preserve_fds:[]`,
so it doesn't know about the xml fd. After this second `None` return, the
xml fd (fd 4 / fd3) might still be open in the outer.

The outer also closes `fd4` at lines 3716–3718 regardless, so this particular
path may not leak. But the **read end** (fd 3) is only closed at 3771–3775
which is AFTER the deliver daemon startup block. If the second
`start_deliver_daemon` succeeds at 3711, `deliver_pid := Some p` executes and
we skip to 3716–3718 which closes fd4. The read end is closed at 3773.
But if the second `start_deliver_daemon` ALSO returns `None`, we fall through
without closing either end at lines 3771–3775.

**Fix:** Unconditionally close both ends of `codex_xml_pipe` at lines 3771–3775
regardless of `deliver_pid` state. The current logic relies on the second call
succeeding to set `deliver_pid`, which is fragile.

---

## Finding 4: `stop_sidecar` wait loop vulnerable to SIGKILL race

**File:** `ocaml/c2c_start.ml`
**Lines:** 3224–3241

```ocaml
let stop_sidecar pid_opt =
  match pid_opt with
  | None -> ()
  | Some p ->
      (try Unix.kill p Sys.sigterm with Unix.Unix_error _ -> ());
      let rec wait_try n =
        if n <= 0 then ()
        else (
          match Unix.waitpid [Unix.WNOHANG] p with
          | 0, _ -> Unix.sleepf 0.1; wait_try (n - 1)
          | _, _ -> ()
        )
      in
      wait_try 20;   (* up to 2s *)
      (try Unix.kill p Sys.sigkill with Unix.Unix_error _ -> ())
```

The outer loop waits up to 2s with `WNOHANG` polling. If the sidecar is in an
un-interruptible kernel call (e.g., blocked on a `read` from an fd that will
never be closed because it was leaked per Finding 2), `waitpid` will keep
returning 0 (child still running), and after 20 iterations the outer sends
`SIGKILL`. But the leaked fd keeps the sidecar's read() blocked forever.
SIGKILL doesn't release fd references — they leak until the process exits.

This is not directly a hang of the **outer**, but it means the sidecar doesn't
exit cleanly, leaving its registration alive in the broker and its inbox
unprocessed.

---

## Finding 5: Tee thread `outer_stderr_fd` close ordering

**File:** `ocaml/c2c_start.ml`
**Lines:** 3860–3882

The tee thread shutdown sequence is well-documented (lines 3860–3870 comment)
and correctly implements: close `outer_stderr_fd` first, then `tee_write_fd`,
then signal stop pipe, then `Thread.join`. This is the correct order.

However, if `outer_stderr_fd` was not set (not captured), the code at 3871
silently ignores the error. This is fine.

---

## Root Cause Hypothesis

The intermittent hang on `c2c stop codex` is most likely caused by **Finding 2**
(fifo fd leaks when `start_deliver_daemon` returns `None`):

1. If `start_deliver_daemon` fails the first time (returns `None`), the
   `request_events_fifo` and `request_responses_fifo` fds leak.
2. On `c2c stop`, the outer tries to gracefully terminate the sidecar.
3. The sidecar may have one of these leaked fds as its stdin/stdout, causing
   it to block indefinitely on read/write.
4. The 2s `stop_sidecar` timeout expires; SIGKILL is sent.
5. The sidecar's blocked fds still reference kernel objects that don't get
   cleaned up, and the outer may also be stuck waiting for the sidecar's
   `waitpid`.

The codex-specific xml fd path (Finding 3) could compound this when the
`--xml-input-fd` path is used.

---

## Fix Plan

1. **[Easy] Remove duplicate `fds_to_close`/`close_unlisted_fds`** — delete lines
   87–116, add reference comment.
2. **[Medium] Add fifo cleanup in `start_deliver_daemon` `None` path** — unlink
   the fifos when the daemon fails to start.
3. **[Medium] Unconditionally close `codex_xml_pipe` ends after daemon startup**
   — remove dependency on `deliver_pid` being set.
4. **[Test] Write unit test for fifo cleanup path** — mock
   `start_deliver_daemon` returning `None`, verify fifos are closed/unlinked.

---

## Status

**Committed:** `2ec67689` on `slice/312-codex-harness-fd-fix`  
**Findings doc:** `.worktrees/312-codex-harness-fd-fix/.collab/findings/2026-04-26T04-30-00Z-jungle-coder-312-codex-harness-fd-leak.md`  
**Build:** `opam exec -- dune build` clean (pre-existing warnings in c2c_worktree.ml)  
**Tests:** c2c_start tests pass. Broker DND test FAIL is pre-existing and unrelated.  
**Installed:** via `just install-all`  
**Peer review:** requested from lyra-quill

---

## Reproduced: No

The hang does not reproduce reliably in my testing. `c2c stop` on a running
codex instance exits cleanly in ~1.8s. The leak likely requires the specific
condition where `start_deliver_daemon` returns `None` during startup, which may
only occur under certain permission or resource conditions.

The fix (cleanup on `None`) is a defensive correctness improvement regardless of
whether the hang is currently reproducible.
