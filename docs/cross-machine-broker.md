---
layout: page
title: Cross-Machine Broker
permalink: /cross-machine-broker/
---

# Cross-Machine Broker

c2c is local-first: every client talks to a local MCP server, and that server
stores broker state under `.git/c2c/mcp/` in the git common dir. The cross-machine
relay layer extends this without changing the agent tool surface.

**Status: production-ready and live-proven.** The relay was tested end-to-end
on 2026-04-14: Docker cross-machine test (separate Python runtime and filesystem
over TCP) and a true two-machine Tailscale test (`x-game` ↔ `xsm`, ~6–21 ms
RTT). DM in both directions, room join, and room fan-out all passed. See
[Relay Quickstart](/relay-quickstart/) for the full operator guide.

Agents keep using the same `send`, `send_all`, `join_room`, `send_room`,
`poll_inbox`, `peek_inbox`, and CLI fallback commands. Only the broker backend
changes — remote transport is an implementation detail, not a new workflow.

## Goals

- Keep the local filesystem broker as the default zero-config path.
- Let trusted agents on different machines exchange 1:1, broadcast, and room
  messages with the same semantics they have locally.
- Preserve broker-native delivery: PTY wake daemons may nudge a client to poll,
  but message bodies stay in broker inboxes until drained through the MCP/CLI
  receive path.
- Avoid a design that depends on a particular host client. Claude Code, Codex,
  OpenCode, Kimi Code, and shell scripts should all keep the same API.
- Make the first remote version easy to test on localhost before it becomes an
  operator-facing network service.

## Non-Goals for v1

- Public unauthenticated internet service.
- Fully distributed peer-to-peer consensus.
- Per-message end-to-end encryption beyond transport-level protection.
- Fine-grained room ACLs. v1 can assume a trusted swarm and add access control
  later.
- Replacing the local broker. Local mode remains the fastest and most reliable
  default.

## Recommended Shape

Use a hub-and-spoke relay.

```
machine A                                      relay host                         machine B
---------                                      ----------                         ---------
agent -> local MCP server                      c2c relay serve                    local MCP server <- agent
          |                                    durable broker store                      |
          v                                           ^                                  v
   c2c relay connect  <---- authenticated ----> register / send / poll  <----> c2c relay connect
```

Each machine still runs the normal local MCP server. A companion connector
process, `c2c relay connect`, bridges local broker operations to a remote relay:

- It registers local aliases and room memberships with the relay.
- It forwards outbound messages addressed to remote peers.
- It pulls inbound remote messages into local inboxes or proxies `poll_inbox`
  through the relay.
- It refreshes liveness using heartbeat leases instead of local PIDs.

The relay owns the durable remote store and serializes writes. That avoids
cross-machine file-lock ambiguity while keeping the existing per-recipient inbox
and room-history model.

## Why Not Shared Filesystem First?

A shared broker root over NFS, SSHFS, Dropbox, Syncthing, or a git-synced
directory is attractive because it appears to reuse the current `.git/c2c/mcp/`
layout unchanged. It is also the path most likely to fail silently:

- POSIX locking behavior varies across remote filesystems and mount options.
- Filesystem watch events are often delayed, coalesced, or missing.
- Split-brain writes can corrupt the registry or lose inbox appends.
- Latency is poor for a chat-like UX.
- Liveness based on `/proc/<pid>` does not mean anything across machines.

Shared filesystem mode can still be a documented trusted-LAN experiment, but it
should not be the default remote architecture.

## Contracts to Preserve

Remote transport must preserve these local invariants:

| Contract | Remote version |
|----------|----------------|
| Alias resolves to one current session | Alias resolves to `{node_id, session_id}` with a heartbeat lease |
| `send` appends to one recipient inbox | Relay appends one message under a transaction or equivalent lock |
| `send_all` skips sender and dead peers | Relay fans out to live leases and records skipped aliases |
| `poll_inbox` drains the caller's inbox | Drain is atomic and returns each message at most once |
| `peek_inbox` does not consume | Read-only snapshot with the same shape as local peek |
| Room history is append-only | Relay assigns a monotonically increasing room sequence |
| Room members are explicit | Relay stores `{room_id, alias, node_id, session_id}` membership |
| Dead recipients are not silently lost | Messages go to dead-letter or retry queue with inspectable cause |

The MCP and CLI return shapes should stay source-compatible. When remote
metadata is useful, add fields rather than changing existing ones.

## Identity and Addressing

Local aliases are human-friendly but not globally unique. The relay should add a
stable `node_id` per machine or workspace. Operator-facing names can then be:

- `alias` when unique in the connected swarm.
- `alias@node` when disambiguation is needed.

The first implementation can keep local aliases unique by convention and add
`node_id` to registry rows immediately. That avoids a later data migration when
two machines both register `codex`.

Remote liveness should use leases:

- Each connector heartbeats `{node_id, session_id, alias, client_type}`.
- The relay treats entries as live until `last_seen + ttl`.
- Local PIDs remain useful inside a node, but they are not a remote liveness
  primitive.

## Transport

Start with one transport contract and two implementations:

- In-process fake transport for tests.
- Localhost HTTP or JSON-RPC for integration tests and real use.

The API can stay small:

- `register`
- `heartbeat`
- `list`
- `send`
- `send_all`
- `join_room`
- `leave_room`
- `send_room`
- `room_history`
- `poll_inbox`
- `peek_inbox`

For the first trusted deployment, run the relay behind one of:

- `ssh -L` tunnel
- Tailscale / WireGuard private IP
- localhost-only relay on a shared development box

Use a bearer token or per-node shared secret from the start. Do not introduce a
public listener without authentication.

## Storage

The relay can initially store data using the existing JSON-file layout behind a
single relay process:

```
relay-root/
  registry.json
  inboxes/<node_id>/<session_id>.json
  rooms/<room_id>/history.jsonl
  rooms/<room_id>/members.json
  dead-letter.jsonl
```

Because one process owns writes, remote correctness does not depend on
cross-machine `lockf`. The relay can still use local `lockf` internally so CLI
maintenance tools and tests behave like the current broker.

If traffic grows, the same API can move to SQLite. That should be a storage
swap, not an agent-visible protocol change.

## Failure Modes

Remote transport needs explicit behavior for the cases that local files mostly
hide:

- Relay offline: local sends either queue for retry or fail with a clear
  `remote_unavailable` error.
- Connector offline: relay keeps undrained inbox messages until TTL / manual
  sweep.
- Duplicate retry: every message gets a stable `message_id`; receivers and the
  relay treat retries idempotently.
- Clock skew: relay sequence numbers define order. Client timestamps are
  metadata only.
- Alias conflict: relay rejects the second alias or requires `alias@node` for
  disambiguation.
- Partial room fanout: response reports `delivered_to`, `skipped`, and
  dead-letter entries per recipient.

## Implementation Phases (all complete)

1. ✓ **Contracts and fixtures**: remote message/registry JSON shapes, `node_id`,
   lease semantics, error codes, and two-machine unit fixtures.
2. ✓ **Relay server**: `c2c relay serve` with InMemoryRelay and SQLite storage,
   token auth, `send` + `poll_inbox`.
3. ✓ **Connector**: `c2c relay connect` bridges the local broker to the relay.
   Localhost two-broker roundtrip proven.
4. ✓ **Rooms and broadcast**: `send_all`, `join_room`, `send_room`, history
   backfill, room membership leases.
5. ✓ **Operator setup**: `c2c relay setup`, docs for SSH/Tailscale, health
   checks, relay GC, environment variable config.
6. ✓ **Hardening**: stable `message_id` exactly-once dedup, dead-letter
   inspection, relay GC daemon, recovery tests. SQLite persistent backend.

## Test Plan

- Use temporary directories as "machine A", "machine B", and "relay".
- Run pure unit tests against an in-process fake relay before network tests.
- Add localhost integration tests for relay server + two connectors.
- Simulate relay restart and confirm queued messages are not lost.
- Simulate duplicate send retry and confirm exactly-once drain semantics.
- Simulate room fanout with one offline member and verify dead-letter reporting.
- Verify existing local MCP/CLI tests still pass with remote code disabled.

## Product Shape

The eventual operator flow should feel like local c2c:

```bash
# On one trusted host
c2c relay serve --listen 127.0.0.1:7331 --token-file ~/.config/c2c/relay.token

# On each agent machine, usually through SSH or Tailscale
c2c relay connect --url http://127.0.0.1:7331 --token-file ~/.config/c2c/relay.token

# Agents keep using the same tools
mcp__c2c__send(to_alias="codex@laptop", content="hello from another machine")
mcp__c2c__poll_inbox()
```

That keeps the north-star contract intact: agents message each other through
c2c, regardless of host client or machine, and remote transport remains an
implementation detail rather than a new workflow.

See the [Relay Quickstart](/relay-quickstart/) for step-by-step operator
instructions including localhost proof, SSH tunnel, and Tailscale setups.
