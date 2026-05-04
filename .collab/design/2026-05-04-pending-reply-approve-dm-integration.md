# Design sketch: wire pending_reply to consume approve DMs

**Author**: stanza-coder
**Date**: 2026-05-04
**Status**: SKETCH (not implemented)
**Cross-ref**: Finding `2026-04-29T00-00-00Z-coordinator1+birch-coder-permission-dm-auto-reject-despite-in-window-approve.md`

## Problem

`open_pending_reply` creates a pending permission entry with a TTL.
The supervisor is notified via DM. The supervisor "approves" by sending
a DM back (e.g. `c2c send <agent> "approve <perm_id>"`). But this DM
lands in the agent's inbox — it never touches the pending_reply state.
The agent polls `check_pending_reply`, which looks up the entry by
`perm_id` and checks `expires_at > now`. Since no code ever marks the
entry as resolved from the DM, the entry expires on schedule and the
agent gets "expired" even though the supervisor approved in-window.

The #490 approval-side-channel (file-based `approval-pending/` +
`approval-verdict/` dirs) was built as a separate mechanism to solve
this class. But the MCP-level `open_pending_reply` / `check_pending_reply`
tools remain broken for the DM-based workflow.

## Options

### Option A: Supervisor calls `check_pending_reply` (no code change)

The intended flow may have been:
1. Agent calls `open_pending_reply` → creates entry, DMs supervisor
2. Supervisor calls `check_pending_reply` with the `perm_id` → entry
   is marked resolved (`mark_pending_resolved`), supervisor gets
   `requester_session_id`
3. Supervisor sends verdict to the agent's session

This works TODAY if supervisors use the MCP tool path. The "bug" is
that supervisors instead send a DM, which doesn't resolve the entry.

**Pro**: No code change. Just documentation + workflow guidance.
**Con**: Supervisors need MCP access to the broker (not always true —
a human operator or a CLI-only agent can't call MCP tools).

### Option B: Broker-side DM interception

Add a DM content pattern that the broker recognizes as a pending_reply
resolution:

```
approve:<perm_id>   → mark_pending_resolved
deny:<perm_id>      → mark_pending_denied (new)
```

In `enqueue_message`, after writing to the recipient's inbox, check
if the `content` matches the pattern AND `from_alias` is in the
entry's `supervisors` list. If so, call `mark_pending_resolved` (or
a new `mark_pending_denied`) as a side-effect.

**Shape** (in `c2c_broker.ml:enqueue_message`):
```ocaml
(* After inbox write, check for pending_reply resolution pattern *)
let () = match parse_pending_reply_verdict content with
  | Some (perm_id, verdict) ->
      (match find_pending_permission t perm_id with
       | Some pending when List.mem from_alias pending.supervisors ->
           let _ = mark_pending_resolved t ~perm_id ~ts:(Unix.gettimeofday ()) in
           (* Optionally write verdict to a sidecar for the agent to read *)
           ()
       | _ -> ())
  | None -> ()
in
```

**Pro**: Works with any send path (CLI, MCP, relay). Supervisors just
send a DM with the right content. The agent's `check_pending_reply`
finds the entry resolved.
**Con**: Content-based dispatch in the broker is a new pattern. Needs
careful escaping (what if a message accidentally contains `approve:per_...`?).
Could use a structured prefix like `[c2c:approve:<perm_id>]` to reduce
collision risk.

### Option C: Deprecate pending_reply in favor of #490

The #490 approval-side-channel (file-based) already solves this:
- Agent writes to `approval-pending/<token>.json`
- Supervisor writes verdict to `approval-verdict/<token>.json`
- Agent polls the verdict file

If the file-based path is the future, deprecate `open_pending_reply` /
`check_pending_reply` and migrate callers to the #490 pattern.

**Pro**: No new broker complexity. Single approval mechanism.
**Con**: Migration cost. MCP tools are already wired; #490 is CLI-only
today. Kimi hooks use the side-channel but other clients may depend on
the MCP tools.

## Recommendation

**Option B** for short-term (low-risk, additive). **Option C** for
long-term (single mechanism, less surface area).

Short-term: add `parse_pending_reply_verdict` to the broker's
`enqueue_message` path. Use a structured prefix
`[c2c:pending-verdict:<perm_id>:<approve|deny>]` to avoid content
collision. The DM still delivers normally (the agent sees it in their
inbox), but the broker also marks the pending entry as resolved.

Long-term: evaluate whether to converge on the file-based #490 path
and deprecate the MCP pending_reply tools.

## Non-goals

- Changing the `check_pending_reply` API shape
- Adding a new MCP tool for supervisors (Option A already works)
- Cross-host pending_reply (relay doesn't participate)
