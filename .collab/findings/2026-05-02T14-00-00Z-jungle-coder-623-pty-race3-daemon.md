# Finding: Race 3 — pty_deliver_loop_daemon unhandled pty_inject exception

**Date**: 2026-05-02T14:00:00Z
**Author**: jungle-coder
**Severity**: HIGH
**Status**: Confirmed — fix needed

## Bug Description

`pty_deliver_loop_daemon` in `ocaml/c2c_pty_inject.ml` lines 84–91 delivers
messages via `pty_inject` inside a bare `List.iter` with no error handling:

```ocaml
List.iter
  (fun (msg : C2c_mcp.message) ->
     pty_inject ~master_fd msg.content;
     Printf.printf "[c2c-deliver-inbox] PTY: injected from %s: %s\n%!"
       msg.from_alias
       (String.sub msg.content 0
          (min (String.length msg.content) 80)))
  messages;
```

If any single `pty_inject` raises an exception (e.g., EPIPE if the PTY master
has been closed by the child process, or EIO if the child has closed the slave
side), the entire `List.iter` aborts. Remaining messages in the batch are NOT
injected — they are silently dropped from the inbox (already drained) without
delivery.

This is the **identical pattern** to Race 1 (#561), which was fixed in
`pty_deliver_loop` (c2c_start.ml lines 3862–3872) by wrapping each
`pty_inject` call in `try/with` and logging the error.

## Root Cause

`pty_deliver_loop_daemon` was not updated when Race 1 was fixed in the
`pty_deliver_loop` variant. The daemon variant (used by `c2c_deliver_inbox
--pty-master-fd`) has the same failure mode.

## Fix

Apply the same per-message error isolation pattern used in `pty_deliver_loop`
(c2c_start.ml lines 3863–3871):

```ocaml
List.iter
  (fun (msg : C2c_mcp.message) ->
     (try pty_inject ~master_fd msg.content
      with e ->
        (* Race 3 fix: per-message error isolation — one failed inject must not
           abort the remaining messages in the batch. The drain_inbox lock is
           already released before this iteration starts, so failures here do
           not affect broker state. Log and continue. *)
        Printf.eprintf "[c2c-deliver-inbox] warning: pty_inject failed for message %s: %s\n%!"
          (Option.value msg.message_id ~default:"<no-id>")
          (Printexc.to_string e));
     Printf.printf "[c2c-deliver-inbox] PTY: injected from %s: %s\n%!"
       msg.from_alias
       (String.sub msg.content 0
          (min (String.length msg.content) 80)))
  messages;
```

Note: `pty_deliver_loop` uses `Option.value msg.message_id` for logging;
`pty_deliver_loop_daemon` uses `msg.from_alias` (which is always present).
Use `msg.message_id` if available, else `msg.from_alias` for consistency.

## Affected Code Path

- **Daemon binary**: `c2c_deliver_inbox --pty-master-fd <fd>`
- **Called by**: `c2c start` spawns `c2c_start` which uses `pty_deliver_loop`
  (already fixed); `c2c_deliver_inbox` standalone daemon uses
  `pty_deliver_loop_daemon` (THIS bug)
- **Delivery surface**: PTY bracketed paste injection
- **Users affected**: Agents using `--pty-master-fd` delivery mode

## Relationship to Race 1 (#561)

Race 1 was fixed in `pty_deliver_loop` (c2c_start.ml). This finding confirms
the same bug exists in `pty_deliver_loop_daemon`. Both should have consistent
error handling.

## Other Races Investigated (NOT confirmed)

- **Orphan inbox drain race**: `with_inbox_lock` in `c2c_broker.ml` uses
  POSIX `fcntl lockf` with proper ordering (registry → inbox). Lock is held
  only during the drain operation. No confirmed issue.
- **Signal delivery gap**: SIGUSR1 signal handler sets a flag; the
  sigusr1_wrapper mechanism handles async delivery in the inner process.
  Watcher blocks on select; inner process does drain. No confirmed race.
- **confirm_registration before drain_inbox**: Lock ordering is
  registry → inbox, correct. No issue found.

## Fix Status

Fix NOT yet implemented. Needed before #623 can be closed.