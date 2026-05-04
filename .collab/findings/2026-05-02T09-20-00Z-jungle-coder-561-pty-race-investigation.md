# #561 PTY Race Investigation — FINDING (in progress)

**Filed by:** jungle-coder
**Date:** 2026-05-02
**Status:** INVESTIGATING — race conditions identified, PTY-specific path TBD

## Summary
Investigating delivery-layer race conditions in the PTY message path. Three candidate
races identified; PTY-specific analysis ongoing.

---

## Race 1: send_all non-atomic fan-out (#488 S2 follow-up)

**Location:** `c2c_broker.ml:send_all` (approx. line ~2260)

**Bug:** `send_all` fans out to multiple recipients by acquiring each recipient's
inbox lock separately. If `enqueue_message` throws for one recipient (e.g.,
inbox lock held by a concurrent drain), the already-enqueued messages stay
queued — the failure is silent to the sender.

```ocaml
(* Fan-out loop: each enqueue is a separate lock acquisition.
   No atomicity guarantee across recipients. *)
List.iter (fun recipient ->
  enqueue_message t ...  (* could raise, already-enqueued stay queued *)
) recipients
```

**Impact:** Recipient R1 gets the message, recipient R2 doesn't. Sender has no
indication of partial failure. Recipient R2 must wait for next `send_all` retry.

**Severity:** MEDIUM — silent partial delivery in multi-recipient broadcast.

---

## Race 2: drain_inbox lock gap (HYPOTHESIS — unconfirmed)

**Hypothesis:** If `drain_inbox`'s `load_inbox` and `save_inbox` are NOT
protected by a single continuous lock acquisition, a concurrent sender could
append to the inbox between the drain's read and write, and the drain's
`save_inbox` (which uses `Open_trunc`) could overwrite the sender's append.

**Status:** NEEDS VERIFICATION. Requires reading the actual
`with_inbox_lock` implementation to confirm whether load and save are
atomically locked.

**Action:** Check `c2c_broker.ml` around line 2431 (`drain_inbox`) and
`with_inbox_lock` (around line 1532) to confirm lock scope.

---

## Race 3: PTY deliver_loop message loss on injection failure

**Location:** `c2c_start.ml:pty_deliver_loop` (line 3825) and
`c2c_pty_inject.ml:pty_inject` (line 22)

**Bug:** `pty_deliver_loop` drains ALL messages from the inbox in one atomic
operation, then iterates injecting each via PTY. If `pty_inject` fails partway
through the iteration (e.g., PTY master fd is closed / EPIPE), remaining
messages are already removed from the inbox — they are lost silently.

```ocaml
(* Drain is atomic — all messages removed from inbox in one lock acquisition *)
let messages = C2c_mcp.Broker.drain_inbox ~drained_by:"pty" broker ~session_id in
List.iter (fun (msg : C2c_mcp.message) ->
  C2c_pty_inject.pty_inject ~master_fd msg.content
  (* If this throws for msg[B], msg[C] is already gone from inbox *)
) messages;
```

**Impact:** If PTY injection fails for message B, message C (and any remaining
messages) are silently dropped from the recipient's inbox. Sender has no
indication. Recipient never sees the messages.

**Severity:** HIGH if confirmed — silent message loss.

---

## Next Steps
1. Verify lock scope in `drain_inbox` — is load+save under one continuous lock?
2. Check if `pty_inject` can fail silently (no exception propagation) in the
   deliver loop context
3. Determine if the "lost bytes" description matches Race 3 or something else
4. File repro recipe once root cause is confirmed