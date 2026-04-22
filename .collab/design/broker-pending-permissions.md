# Broker-Side Pending Permission Tracking (M2/M4)

**Date**: 2026-04-22
**Author**: ceo
**Status**: Design draft

## Context

The alias-hijack vulnerability allows an attacker who steals an alias (between when a permission request is sent and when its reply arrives) to receive permission replies intended for the original owner.

**M3** (plugin-side, committed 6e4c671) prevents spoofed replies — verifies replies come from a supervisor we asked. This closes the external attacker vector.

**M2/M4** address the remaining gap: after an alias is legitimately reassigned (original owner died + swept), the new owner can receive orphaned permission replies.

## Threat Model

1. Agent A (`session_a`, alias `jungel-coder`) sends permission request to `coordinator1`
2. `coordinator1` replies `permission:xyz:approve-once` → broker → alias `jungel-coder`
3. Agent A dies; `sweep` removes registration
4. Agent B (`session_b`) starts, registers as alias `jungel-coder`
5. Broker resolves alias `jungel-coder` → `session_b`
6. Reply intended for Agent A is delivered to Agent B

**Note**: This requires the alias to be free when the reply arrives. With the current 1800s provisional sweep TTL, the window is ~30 minutes. M4 (block alias reuse while prior owner has pending state) eliminates this window entirely.

## Design: M2 — Broker Permission Request Registry

### New Ephemeral Store

```ocaml
(* c2c_mcp.ml *)
type pending_permission = {
  perm_id : string;
  requester_session_id : string;
  requester_alias : string;
  supervisors : string list;   (* aliases of supervisors asked *)
  created_at : float;
  expires_at : float;
}

let pending_permissions : (string, pending_permission) Hashtbl.t
  = Hashtbl.create 16
```

### New RPC: `open_permission_request`

Called by the plugin **when it sends** a permission request to supervisors.

```
open_permission_request(perm_id, supervisors[]) → ok | error
```

- Validates caller is a live registered session
- Stores `{perm_id, requester_session_id, requester_alias, supervisors, created_at, expires_at}`
- TTL: 10 minutes (configurable via `C2C_PERMISSION_TTL` env, default 600s)

### New RPC: `check_permission_reply`

Called by the plugin **when it receives** a permission reply message.

```
check_permission_reply(perm_id, reply_from_alias) →
  { valid: bool;
    requester_session_id: string option;
    error: string option }
```

- Looks up `pending_permission` by `perm_id`
- Returns:
  - `{valid: true, requester_session_id}` if reply is from a listed supervisor
  - `{valid: false, error: "unknown permission ID"}` if not found
  - `{valid: false, error: "reply from non-supervisor: X"}` if `reply_from_alias ∉ supervisors`

### Broker Envelope Validation (Optional Enhancement)

Instead of requiring the plugin to call `check_permission_reply` separately, the broker could intercept messages matching `permission:${id}:*` and validate automatically before delivery. This requires:

1. Identifying permission reply messages in `deliverMessages` or `poll_inbox`
2. Looking up the pending permission state
3. Validating `from_alias` against stored `supervisors` list

**Tradeoff**: Automatic validation is cleaner for clients but requires broker to parse message content. `check_permission_reply` is simpler but requires the plugin to call it explicitly.

## Design: M4 — Alias Reuse Guard

When a new registration arrives for alias `X`:

```
1. Check if any pending_permission exists for alias X (by scanning store)
2. If yes AND the prior owner is not alive (PID dead / confirmed_at stale):
   - Allow registration (prior owner is dead anyway)
3. If yes AND the prior owner IS alive:
   - Reject registration with error: "alias X has pending permission state from prior owner"
4. If no pending permissions for X:
   - Allow registration (normal path)
```

**Edge case**: What if the prior owner died but hasn't been swept yet? The new registration should wait or retry. The existing `alias_occupied_guard` (Guard 2) already prevents alias stealing from live sessions.

## Race: Session Restart During Pending Permission

Scenario: Agent A sends permission request, then restarts (new `session_id_a2`) while reply is in flight.

- Broker has `pending_permission` keyed on `session_id_a1`
- Reply arrives for `session_id_a1` → routed correctly
- Agent A re-registers as `session_id_a2` → broker has two entries for same alias?

**Mitigation**: On re-registration with same alias, the plugin should:
1. Call `close_permission_requests(session_id_old)` before re-registering, OR
2. The broker should update `pending_permission` entries on re-registration to point to the new session_id

Simpler: just let the reply arrive at the old session_id and get dead-lettered. The permission request will timeout on the client side. Agent A will retry after restart if needed.

## Implementation Locations

| Component | Location |
|-----------|----------|
| `pending_permission` type | `c2c_mcp.ml` (Broker module) |
| Ephemeral store (TTL sweep) | `c2c_mcp.ml` — integrate with existing sweep |
| `open_permission_request` RPC | `c2c_mcp.ml` — new tool |
| `check_permission_reply` RPC | `c2c_mcp.ml` — new tool |
| Plugin integration | `.opencode/plugins/c2c.ts` — call new RPCs around permission send/receive |
| M4 alias reuse guard | `c2c_mcp.ml` — `register_session` function |

## Questions / Open Issues

~~1. **TTL**: 10 minutes seems reasonable for permission timeouts.~~ → **Use `C2C_PERMISSION_TIMEOUT_MS` if set, else 600s. Source from plugin env at call time.**
~~2. **Cleanup**: lazy vs eager?~~ → **Both: lazy-evict-on-access for correctness (never return expired entries), piggyback eager sweep onto existing GC cycle for memory hygiene.**
~~3. **Multi-supervisor close-after-first**~~ → **Yes, close after first valid reply — matches plugin promise resolution (resolve() fires once). Further replies are logged as potential spoofing.**
~~4. **Question permissions**~~ → **Yes, generalize from day 1: `open_pending_reply(id, kind, supervisors)` with `kind: "permission" | "question"`. One RPC pair covers both surfaces.**
~~5. **Compatibility fallthrough**~~ → **Advisory until all plugins updated. Add broker log line when unregistered perm_id receives a reply — enables observation of transition.**

**§ Broker Envelope Validation**: Skip for v1. Explicit RPC calls are clearer, easier to test, don't require broker to parse message content. Revisit only if plugin churn is painful.

## Status

**Ready for implementation** (2026-04-22, reviewed by coordinator1)
