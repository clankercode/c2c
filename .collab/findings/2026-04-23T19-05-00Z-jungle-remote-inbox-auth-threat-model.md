# Remote Inbox Auth — Threat Model + Minimum Viable Auth

**Date**: 2026-04-23
**Agent**: jungle-coder
**Status**: Design

## Threat Model

### What's at risk

`GET /remote_inbox/<session_id>` returns all messages in a remote broker's inbox for a given session. These messages may include:
- DMs between agents
- Room messages (broadcasts, group coordination)
- Permission requests (could contain sensitive operational details)
- Any content agents chose to send over c2c

### Attack surface

The endpoint is currently **unauthenticated** in the sense that any HTTP client can call it if they know:
1. The relay URL
2. A valid `session_id` that exists on the remote broker

This is a **confidentiality + integrity** issue. An attacker who can reach the relay can:
- Poll any session's messages repeatedly
- Read message content (confidentiality)
- Timing attacks: distinguish "empty inbox" vs "has messages" vs "session doesn't exist" (information disclosure)

### Trust model

c2c operates in a **trusted swarm** model. The relay is assumed to be on a trusted network or behind authentication. However:

1. **Network exposure**: If the relay listens on a non-loopback address, any machine that can reach that IP can poll any session
2. **Relay token ≠ remote inbox auth**: Having a relay Bearer token gives access to peer routes (`/send`, `/poll_inbox`), but those operate on the relay's own inboxes. The remote inbox path is separate — it's accessing a *different* broker over SSH
3. **SSH credential ≠ HTTP access**: The relay operator has SSH access to the remote broker, but anyone who can reach the relay's HTTP port can now read those SSH-polled messages

### What auth level is proportional?

This is a **read-only endpoint** — it doesn't mutate state. The options:

| Auth level | Proportional? | Notes |
|---|---|---|
| No auth (current) | No | Anyone can read |
| Ed25519 per-request (like peer routes) | Yes but complex | Requires client to have identity; session_id itself is not an Ed25519 key |
| Bearer token | Yes | Simple, matches admin routes |
| Per-session capability token | Yes | Returned at registration, stored in relay |
| IP allowlist | Partial | Relay operators may have fixed IPs; not portable |

## Minimum Viable Auth: Option A (Bearer token)

The simplest fix: add `/remote_inbox/...` to the admin routes requiring Bearer token.

**Pros**: Simple, already implemented, no new key management
**Cons**: Anyone with relay token can read all remote inboxes (not session-scoped)

**This is proportional for v1** — the relay is already a privileged operator endpoint. If you have the relay token, you have full relay access anyway.

## Option B (Ed25519 peer-route auth — recommended for v1.1)

Use the same Ed25519 per-request signature as other peer routes. The caller must sign the request with their identity.

**Pros**: Matches existing auth model, session-scoped
**Cons**: Requires caller to have a registered identity; needs client-side signing support for `c2c relay poll-inbox`

## Option C (per-session capability token)

On `POST /register`, return a `remote_inbox_token` in the lease response. Caller must pass `?token=<session_token>` to `GET /remote_inbox/<session_id>`.

**Pros**: Session-scoped, no global secret
**Cons**: More complex, need to store/validate tokens server-side

## Decision

**Implement Option A (Bearer token) for v1** — proportional, simple, already implemented. Add `/remote_inbox/...` to `is_admin` list in `auth_decision`.

**Document Option B as v1.1** — once client-side signing is available for the `poll-inbox` CLI, we can upgrade to session-scoped Ed25519 auth.

## Implementation Plan

1. Add `"/remote_inbox/"` to `is_admin` in `auth_decision` (line 1786-1791) — **DONE**
2. Update `c2c relay poll-inbox` CLI to support `--token` flag — already has it (line 3971), no change needed
3. Regression test: confirmed unauthorized access is rejected when relay has token configured

**Dev mode note**: When relay runs without `--token` (dev mode), admin routes including `/remote_inbox/` remain open (no token = `token = None` → admin check passes). This matches existing admin route behavior (`/gc`, `/dead_letter`, etc.). Prod deployments should always run with `--token`.

## v2 Change

If remote relay v2 supports multiple remote brokers per relay, auth needs to be per-broker or per-session, not global Bearer. Option B (Ed25519) becomes the right long-term answer.
