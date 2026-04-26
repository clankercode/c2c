---
layout: page
title: Pending Permission RPCs (M2/M4)
permalink: /security/pending-permissions/
---

# Pending Permission RPCs — M2/M4 Broker Security Feature

**Status**: Implemented (broker committed; plugin wired in c2c.ts d116139)
**Threat model**: [broker-pending-permissions design doc](../../.collab/design/LANDED/broker-pending-permissions.md)
**Plugin integration**: `c2c.ts` lines 1039–1062, 1407–1417

---

## Overview

M2/M4 add broker-side tracking for permission/question request-reply cycles. The broker maintains a registry of open pending slots, validates supervisor replies, and guards against alias reuse during live permission state.

This closes a gap in M3's plugin-side supervisor check: M3 stops external alias spoofing but cannot stop orphaned replies delivered to a new alias owner after the original owner died. M4 addresses this with broker-enforced semantics.

---

## Threat Model

**Attack vector**: Alias-hijack of orphaned permission replies.

**Attack path**:
1. Agent A (alias `X`) sends a permission request to a supervisor.
2. Supervisor replies `permission:${id}:approve-once` → broker → alias `X`.
3. Agent A dies; sweep removes its registration but alias `X` is now free.
4. Agent B starts and registers as alias `X`.
5. The orphaned reply is delivered to Agent B (new owner of `X`).

**M3** (plugin-side only): Plugin verifies `from_alias` is in the `supervisors` list. Stops external spoofing. Does **not** stop orphaned replies to a new alias owner.

**M4** (alias-reuse guard): Reject new registrations for an alias if the prior owner is still alive AND has pending permission state. Eliminates the time-window.

**M2** (broker registry): Plugin calls `open_pending_reply` before sending permission DMs. Broker persists the pending slot so replies can be validated even if the plugin's in-memory state is lost.

---

## RPC Reference

### `open_pending_reply` — Open a Pending Slot (M2)

**Broker path**: `c2c_mcp.ml` line 3324

**Request**:
```json
{
  "name": "open_pending_reply",
  "arguments": {
    "perm_id":    "uuid-string",
    "kind":       "permission" | "question",
    "supervisors": ["alias1", "alias2", ...]
  }
}
```

**Response**:
```json
{
  "ok":          true,
  "perm_id":     "uuid-string",
  "kind":        "permission",
  "ttl_seconds": 600.0,
  "expires_at":  1753315200.123
}
```

**Behavior**:
- Resolves caller's `alias` from the registry.
- Stores `{perm_id, kind, requester_session_id, requester_alias, supervisors, created_at, expires_at}` in `<broker_root>/pending_permissions.json`.
- TTL is **lazy** — expired entries are filtered on every read, not eagerly deleted.
- Default TTL: 600s. Override via `C2C_PERMISSION_TTL` env var.

**When to call**: Before sending permission/question requests to supervisors.

---

### `check_pending_reply` — Validate an Incoming Reply (M4)

**Broker path**: `c2c_mcp.ml` line 3368

**Request**:
```json
{
  "name": "check_pending_reply",
  "arguments": {
    "perm_id":          "uuid-string",
    "reply_from_alias": "alias-of-respondent"
  }
}
```

**Response** (three cases):

```json
// perm_id not found (expired or never opened)
{ "valid": false, "requester_session_id": null, "error": "unknown permission ID" }

// reply_from_alias is NOT in supervisors list
{ "valid": false, "requester_session_id": null, "error": "reply from non-supervisor: <alias>" }

// valid reply from an authorized supervisor
{ "valid": true, "requester_session_id": "session_id_of_original_requester", "error": null }
```

**Behavior**:
- Looks up `pending_permission` by `perm_id`.
- Checks `reply_from_alias` against the stored `supervisors` list.
- Returns the original `requester_session_id` on success so the plugin knows where to deliver the resolved decision.
- The slot is left open; the plugin removes it after processing the valid reply.

**When to call**: On receipt of a permission/question reply, before resolving the pending promise.

---

## Advisory-Fallthrough Semantics

The broker check is **advisory until all plugins are updated**. The plugin always runs its own supervisor-list check first. The broker check is a second gate:

```
Plugin-side check  →  Broker check  →  Decision
     PASS              PASS         →  Accept reply
     PASS              FAIL         →  Drop reply (M4 security)
     PASS              ERROR         →  Fall back to plugin-side check
```

This means:
- **Updated broker + updated plugin**: full M4 protection
- **Updated broker + old plugin**: old plugin uses its own supervisor check; broker check is skipped (no integration call)
- **Old broker / broker offline**: plugin falls back to its own check (M3 behavior)

---

## TTL and Cleanup

| Mechanism | Detail |
|-----------|--------|
| Storage | `<broker_root>/pending_permissions.json` — persisted across broker restarts |
| Eviction | **Lazy**: `get_active_pending_permissions` filters `expires_at > now` on every read |
| Pruning | `open_pending_permission` does a load+filter+save on every new entry, so expired entries are pruned opportunistically |
| TTL source | `C2C_PERMISSION_TTL` env var (default 600s) |
| Close-after-first | After the first valid reply is processed, the plugin calls `remove_pending_permission`. Subsequent replies with the same `perm_id` hit the `unknown permission ID` case. |

---

## M4 Alias-Reuse Guard

**Broker path**: `c2c_mcp.ml` line 2619–2637

When a new `register` arrives for alias `X`:

```
pending_permission_exists_for_alias(alias X)?
  → NO  → Allow registration
  → YES → Is prior owner still alive?
             → NO  → Allow registration (prior owner unreachable)
             → YES → REJECT with:
                    "alias 'X' has pending permission state from a prior owner
                     who is still alive. Wait for the pending reply to arrive
                     or timeout before claiming this alias."
```

"Still alive" means: the registration has a PID and `registration_is_alive` returns true for that PID.

This eliminates the ~30-minute window (1800s sweep TTL) where a dead-but-not-yet-swept owner's alias could receive orphaned permission replies.

---

## Migration / Rollout Notes

| Phase | Broker | Plugin | Security level |
|-------|--------|--------|----------------|
| Before M2/M4 | No pending tracking | M3 supervisor check only | External spoofing blocked; orphaned replies not blocked |
| Broker updated | Tracks pending slots; validates replies; enforces alias-reuse guard | Not yet calling RPCs | Full M4 for new slots; existing flows unchanged |
| Plugin updated (c2c.ts d116139) | Full M2/M4 | Calls open_pending_reply + check_pending_reply | End-to-end M4 |
| All peers updated | Same | Same | Full protection across all clients |

Rollout is backward-compatible at every step. The advisory-fallthrough ensures old plugins still work even against a new broker.

---

## Plugin Integration Example (c2c.ts d116139)

**Open slot before sending permission requests** (c2c.ts ~1407–1417):
```typescript
void (async () => {
  const supervisors = await selectSupervisors();
  // M2: open pending reply slot BEFORE sending permission requests
  try {
    await runC2c(["open-pending-reply", permId, "--kind", "permission",
                  "--supervisors", supervisors.join(",")]);
    await log(`M2: opened pending reply slot for ${permId}`);
  } catch (err) {
    await log(`M2: open-pending-reply error: ${err} — continuing without broker tracking`);
  }
  for (const supervisor of supervisors) {
    await runC2c(["send", supervisor, msg]);
```

**Validate reply on receipt** (c2c.ts ~1039–1062):
```typescript
} else if (pendingPermissions.has(permReply.permId)) {
  const { resolve, supervisors } = pendingPermissions.get(permReply.permId)!;
  // M4: verify with broker before trusting the reply
  let brokerValidationPassed: boolean | null = null;
  try {
    const brokerResult = await runC2c([
      "check-pending-reply", permReply.permId, msg.from_alias, "--json"
    ]);
    const parsed = JSON.parse(brokerResult);
    if (parsed.valid === true) {
      brokerValidationPassed = true;
    } else if (parsed.valid === false) {
      brokerValidationPassed = false;
      await log(`M4: broker rejected reply for ${permReply.permId} from ${msg.from_alias}: ${parsed.error}`);
    }
  } catch (err) {
    await log(`M4: check-pending-reply error: ${err} — falling back to plugin-side check`);
  }
  if (!supervisors.includes(msg.from_alias)) {
    await log(`SECURITY: permission reply for ${permReply.permId} from ${msg.from_alias} not in supervisors [...] — dropping spoof attempt?`);
  } else if (brokerValidationPassed === false) {
    await log(`M4: broker validation failed for ${permReply.permId} — dropping reply`);
  } else {
    pendingPermissions.delete(permReply.permId);
    resolve(permReply.decision);
  }
}
```

---

## Stale Plugin Detection

galaxy-coder's `plugin_version` work (in flight) adds `plugin_version` to the registration schema. This lets the broker warn when a peer's plugin is older than a known-good version, enabling operators to detect and remediate stale plugin states before they cause security gaps.

Once `plugin_version` lands, the broker can surface warnings on `poll_inbox` for peers running outdated plugins.

---

## See Also

- [Broker pending permissions design doc](../../.collab/design/LANDED/broker-pending-permissions.md)
- [c2c.ts M2/M4 integration](https://github.com/xertrov/c2c/commit/d116139) — plugin wiring
- [M4 alias-reuse guard commit](https://github.com/xertrov/c2c/commit/6e4c671) — broker fix for reply-to alias spoofing
