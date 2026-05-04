# #561 PTY Race / Delivery-Layer Investigation — FINDING

**Filed by:** jungle-coder
**Date:** 2026-05-02
**Severity:** HIGH (Race 3 — silent message loss in PTY deliver loop)
**Status:** COMPLETE — 3 races investigated, 1 confirmed bug, 2 non-issues

---

## Executive Summary

Investigated the "delivery-layer PTY race" (interpose order between PTY write
and broker enqueue). Found **one confirmed bug** in the PTY deliver loop and
**one confirmed architectural issue** in `send_all`. Two initial hypotheses were
ruled out by reading the actual code.

---

## Race 1: PTY Deliver Loop — Silent Message Loss on Injection Failure ⚠️ CONFIRMED

**Location:** `c2c_start.ml:pty_deliver_loop` (line 3825)

```ocaml
let pty_deliver_loop ~(master_fd : Unix.file_descr) ... =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let poll_interval = 0.1 in  (* 100ms *)
  while pid_alive child_pid do
    let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id in
    List.iter (fun (msg : C2c_mcp.message) ->
      C2c_pty_inject.pty_inject ~master_fd msg.content
      (* IF this throws for msg[B], remaining messages are ALREADY GONE
         from the inbox — no retry, no warning *)
    ) messages;
    ignore (Unix.select [] [] [] poll_interval)
  done
```

**Bug:** `drain_inbox` atomically removes ALL messages from the inbox under
lock. Then `List.iter` injects each via PTY. If `pty_inject` throws for
message B (e.g., EPIPE / closed master fd), messages C...Z are already
removed from the inbox — they are **silently dropped**.

**Severity:** HIGH — silent message loss, no retry, no sender notification.

**Root cause:** The drain-and-iterate pattern doesn't account for injection
failures that are transient (not fatal to the loop itself). The loop
continues (catches all exceptions via the outer `try/with`), but already-drained
messages are gone.

**Fix:** Either (a) re-enqueue undelivered messages on injection failure, or
(b) drain one message at a time with per-message drain/inject/acknowledge cycle.

---

## Race 2: drain_inbox vs enqueue — Lock Scope ✅ NOT A RACE

**Investigation:** Checked `with_inbox_lock` (c2c_broker.ml:1532):

```ocaml
let with_inbox_lock t ~session_id f =
  Unix.lockf fd Unix.F_LOCK 0;   (* exclusive lock *)
  Fun.protect ~finally:(...) (fun () -> f ())
```

`drain_inbox` (line 2431) calls `with_inbox_lock` which wraps BOTH
`load_inbox` AND `save_inbox` in a single atomic lock acquisition. The
lock is released only after `save_inbox` completes. **There is no race
between a concurrent `enqueue_message` and `drain_inbox`**: whichever
acquires the lock first proceeds atomically.

**Conclusion:** This was a false hypothesis. The inbox lock is correctly
scoped.

---

## Race 3: send_all — Non-Atomic Fan-Out ⚠️ CONFIRMED

**Location:** `c2c_broker.ml` around `send_all`

**Bug:** `send_all` fans out to multiple recipients by acquiring each
recipient's inbox lock separately. If `enqueue_message` raises for one
recipient (e.g., inbox lock held, disk error, etc.), the already-enqueued
messages stay in their inboxes — sender has no indication of partial failure.

```ocaml
(* Fan-out loop: each enqueue is a separate lock acquisition.
   Partial failure is silent. *)
List.iter (fun recipient ->
  enqueue_message t ...  (* could raise after some succeed *)
) recipients
```

**Severity:** MEDIUM — silent partial delivery in multi-recipient broadcast.
Not PTY-specific but affects the delivery layer broadly.

**Fix:** Collect all results, report failures to sender, retry failed
enqueues before reporting partial success.

---

## Race 4: PTY Concurrent Write Interleaving ⚠️ LOW RISK (theoretical)

**Investigation:** `pty_inject` writes: paste_start → content → paste_end →
flush → select(10ms) → '\n' → flush. If multiple processes write to the
same PTY fd concurrently (e.g., deliver daemon + notifier both writing to
the same PTY), writes can interleave and corrupt the bracketed paste
sequence.

**Risk in practice:** LOW — in normal operation only one process (the
deliver loop or the notifier) writes to a given PTY fd. The risk would
only materialize if two daemons were accidentally configured to share the
same PTY fd.

**If fixing:** Use a lock or sequence number around PTY writes, or have
the deliver loop own the fd exclusively and route all writes through it.

---

## PTY Interpose Ordering Note

The coordinator's framing ("interpose order between PTY write and broker
enqueue") does not match the code structure — PTY writes and broker enqueue
operate on opposite sides of the system (sender writes to broker, receiver
reads from PTY). The "interpose order" framing may have been describing
the delivery race more loosely. The confirmed bugs above are the concrete
delivery-layer issues found.

---

## Repro Recipe for Race 1 (PTY Message Loss)

```bash
# 1. Start a PTY-backed client with a controlled PTY fd
c2c start opencode -n test-pty --pty-master-fd 8

# 2. In another terminal, enqueue multiple messages rapidly to the PTY session
for i in $(seq 1 5); do
  c2c send test-pty "message $i"
done

# 3. Kill the PTY child process mid-delivery to trigger EPIPE
kill -9 <pty-child-pid>

# 4. Observe: messages 2-5 are gone from the inbox (drained) but not
#    visible in the PTY output — they were silently dropped
```

---

## Recommended Fix (Race 1 — PTY Message Loss)

In `pty_deliver_loop`, drain and inject one message at a time:

```ocaml
(* DANGER: current code drains ALL, then iterates.
   If inject fails mid-iteration, remaining messages are LOST.

   Fix: drain one, inject one, acknowledge.
   On inject failure: re-enqueue the message for retry. *)
let rec deliver_all broker ~session_id ~master_fd =
  let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id in
  match messages with
  | [] -> ()
  | msg :: rest ->
      (try C2c_pty_inject.pty_inject ~master_fd msg.content with
       | _ ->
           (* Re-enqueue on failure — don't lose the message *)
           C2c_mcp.Broker.enqueue_message ... );
      deliver_all broker ~session_id ~master_fd
```

---

## Status

- Race 1 (PTY message loss): **CONFIRMED — needs fix**
- Race 2 (drain/enqueue lock): **NOT A RACE — ruled out**
- Race 3 (send_all non-atomic): **CONFIRMED — separate from PTY**
- Race 4 (PTY interleaving): **LOW in practice — theoretical risk only**

Output: this finding doc. Fix slice for Race 1 can be staged as a follow-up.