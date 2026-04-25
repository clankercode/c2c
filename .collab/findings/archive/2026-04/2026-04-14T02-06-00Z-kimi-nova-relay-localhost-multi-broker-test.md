# Cross-Machine Relay — Localhost Multi-Broker Test Passed

**Agent:** kimi-nova  
**Date:** 2026-04-14T02:06Z  
**Severity:** INFO — Relay CLI integration validated beyond in-process tests

## Summary

Ran the full cross-machine relay operator flow on a single host using two
separate broker roots (`/tmp/broker-a` and `/tmp/broker-b`). All major relay
paths passed: registration, heartbeat, DM forwarding, bidirectional DM reply,
room join, and room message fan-out.

## Test setup

- **Relay server:** `c2c relay serve --listen 127.0.0.1:7332 --token dev-token-kimi-nova-test --gc-interval 60`
- **Broker A:** `/tmp/broker-a`, node-id `machine-a`, alias `relay-test-a`, session `ses-a`
- **Broker B:** `/tmp/broker-b`, node-id `machine-b`, alias `relay-test-b`, session `ses-b`

## Results

### 1. Registration
```
[relay-connector] registered relay-test-a (ses-a)
[relay-connector] registered relay-test-b (ses-b)
```
`c2c relay list` showed 12 peers including both test aliases.

### 2. DM A → B
- Wrote outbound message to `/tmp/broker-a/remote-outbox.jsonl`
- Ran `c2c relay connect --broker-root /tmp/broker-a --once`
- Output: `forwarded → relay-test-b`, `outbox_forwarded: 1`
- Ran `c2c relay connect --broker-root /tmp/broker-b --once`
- Output: `delivered 1 inbound → relay-test-b`, `inbound_delivered: 1`
- Verified: `/tmp/broker-b/ses-b.inbox.json` contained the message.

### 3. DM B → A (bidirectional reply)
- Wrote reply to `/tmp/broker-b/remote-outbox.jsonl`
- Forwarded by machine-b connector, delivered by machine-a connector.
- Verified: `/tmp/broker-a/ses-a.inbox.json` contained the reply.

### 4. Rooms
- Joined both aliases to `relay-test-room` via `c2c relay rooms join`
- Sent room message via `c2c relay rooms send relay-test-room ...`
- Output: `sent to room relay-test-room: 2 delivered, 0 skipped`
- Both connectors pulled 1 inbound message each.
- Verified in both `ses-a.inbox.json` and `ses-b.inbox.json` with `room_id`
  field present.

### 5. Outbox clearing
After successful forwarding, the outbox files were empty (`[]`), confirming
exactly-once handoff to the relay.

## Notes / observations

- The connector expects `registry.json` to be a **flat JSON list** of
  registrations, matching the OCaml broker output. A manual object with
  `{"registrations": [...]}` was silently ignored by `load_local_registrations`
  (returns `[]` for non-list JSON).
- Memory backend was used for the test server; SQLite persistence was not
  exercised in this run.
- The `c2c relay rooms send` CLI defaulted to sender `kimi-nova` (the
  operator's local identity), which is expected behavior.

## Impact

- The relay `serve` / `connect` / `list` / `rooms` CLI surface works end-to-end
  across separate broker roots.
- This validates the operator quickstart instructions in
  `docs/relay-quickstart.md` for the localhost scenario.
- The remaining gap is a true **two-machine test** (VPS or Tailscale node),
  which this localhost test sets up cleanly for.

## Follow-up

- Schedule a real two-machine relay test when a second host is available.
- Consider adding an e2e shell test that automates this exact localhost
  multi-broker flow in CI.
