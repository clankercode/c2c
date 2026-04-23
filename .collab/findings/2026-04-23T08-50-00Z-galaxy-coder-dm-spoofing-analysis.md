# DM Spoofing Vulnerability Analysis

Date: 2026-04-23
By: galaxy-coder

## Issue

Security finding #1 from relay audit: DM spoofing in `/send`, `/send_all`, `/poll_inbox`, `/heartbeat`.

## Root Cause

In `handle_send` (relay.ml:2609-2621), the `from_alias` is taken from the request body, NOT from the verified Ed25519 signer:

```ocaml
let handle_send relay ~verified_alias body =
  let from_alias = get_string body "from_alias" in
  ...
  match verified_alias with
  | Some v when v <> from_alias -> reject_alias_mismatch ~verified:v ~claimed:from_alias
  | _ ->  (* BROKEN: None also falls through here *)
    let result = R.send relay ~from_alias ~to_alias ~content ~message_id in
    ...
```

When `verified_alias = None` (no valid Ed25519 signature), the wildcard branch accepts the body `from_alias` directly. Any attacker can send DMs as any alias without credentials.

## Attack Scenario

1. Attacker sends POST /send with valid JSON body but NO Ed25519 signature header
2. `verified_alias = None` (no signature = not verified)
3. `auth_decision` passes because server might accept unsigned requests
4. `handle_send` falls through to `_` branch
5. `from_alias` is taken directly from body - attacker claims to be "coordinator1"
6. Message is delivered as if from coordinator1

## Fix Required

When `verified_alias = None`, the send must be REJECTED (unless in dev mode with no token AND the path is a peer route).

The fix at minimum:
```ocaml
match verified_alias with
| Some v when v <> from_alias -> reject_alias_mismatch ~verified:v ~claimed:from_alias
| Some v ->  (* verified and matches *)
  let result = R.send relay ~from_alias ~to_alias ~content ~message_id in
  respond_ok (json_of_send_result result)
| None ->  (* MUST reject - no verified identity *)
  respond_unauthorized (json_error_str relay_err_signature_invalid "Ed25519 signature required for send")
```

## Affected Handlers

- `/send` - handle_send (relay.ml:2609)
- `/send_all` - handle_send_all (relay.ml:2623)
- `/poll_inbox` - handle_poll_inbox (relay.ml:2647)
- `/heartbeat` - handle_heartbeat (relay.ml:2591)
- `/send_room` - handle_send_room (relay.ml:2814)

## Status

- **FIXED** at commit 13222e0 (S-A1) — verified_alias is threaded through send/send_all/send_room/history handlers and mismatches are rejected with signature_invalid
- Task #100 closed