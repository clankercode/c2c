# Remote Inbox Auth v2 — Ed25519 Session-Scoped Upgrade

**Date**: 2026-04-23
**Agent**: jungle-coder
**Status**: Design only — no implementation

## Background

v1 (commit 0a7389b) added Bearer-token auth to `GET /remote_inbox/<session_id>`, making it an admin route. This is proportional for a single-operator relay where anyone with the relay token has full access.

v2 addresses the gap: **Bearer token is relay-global, not session-scoped**. Any client with the relay token can poll any session on any remote broker.

## When to Upgrade

Trigger v2 implementation when:
1. Multiple distinct operators share a relay (not just a single swarm operator)
2. Remote relay transport is used across trust boundaries (e.g., open-source agents using a public relay)
3. A breach of the relay token would compromise all sessions across all remote brokers

For a single-operator swarm (current setup), v1 is sufficient.

## Threat Model Delta (v1 → v2)

| Threat | v1 | v2 |
|---|---|---|
| Relay token stolen → read all remote inboxes | Yes | No — Ed25519 is session-scoped |
| Operator error: wrong session poll | Possible (no session isolation) | Mitigated by signing requirement |
| Compromise of session identity key | Session only | Session only |
| Relay token transmitted in clear | Bearer header | Not used for remote inbox |

## Option B: Ed25519 Session-Scoped Capability

### Registration Flow

On `POST /register`, the server already returns a lease with session metadata. Extend this to include a **remote inbox proof** — a signed capability token for `GET /remote_inbox/<session_id>`.

```
Response from POST /register:
{
  "ok": true,
  "session_id": "sess-abc",
  "alias": "my-alias",
  "lease": { "expires": ... },
  "remote_inbox_capability": {
    "session_id": "sess-abc",
    "expires": <lease.expires>,
    "signature": "<Ed25519 signature of session_id|expires using relay identity>"
  }
}
```

### Poll Flow

Client calls `GET /remote_inbox/<session_id>?capability=<base64-encoded-capability>`.

Server verifies:
1. `capability.session_id == <path session_id>`
2. `capability.expires > now()`
3. `capability.signature` is valid Ed25519 over `session_id|expires` using relay identity public key

If all pass → deliver inbox. If any fail → 401.

### Migration Path (Grandfather Admin-Token Users)

1. **Phase 1**: Accept both Bearer and capability (opt-in via `?capability=...`)
2. **Phase 2**: Deprecate Bearer for `/remote_inbox/` (warn in logs)
3. **Phase 3**: Require capability, reject Bearer (admin token users must re-register to get capability)

Graceful: existing sessions with valid leases get capabilities on next heartbeat/renewal. No forced re-registration required.

### Admin Token Grandfathering

Operators with existing `--token` configured keep using it for:
- `/gc`, `/dead_letter`, `/admin/unbind` (unchanged — still admin routes)
- Legacy clients that haven't implemented capability flow

New relay deployments should prefer capability auth over admin token for remote inbox access.

## Implementation Sketch (future)

1. Add `remote_inbox_capability` to `handle_register` response (relay.ml)
2. Sign with existing relay Ed25519 identity (same key as peer-route signatures)
3. Add `verify_remote_inbox_capability` to `auth_decision` or inline in `handle_remote_inbox`
4. Client: extract capability from register response, pass as `?capability=...` query param
5. Add test: valid capability → ok, tampered/expired/wrong-session → 401

## Open Questions

- Should capability be per-session or per-registration? (Per-session: same as above. Per-registration: same session_id can have multiple capability tokens if multiple clients share a session — probably undesirable.)
- Should we rotate the relay identity key? If so, old capabilities signed with retired key must be rejected — need key version/timestamp in capability.
