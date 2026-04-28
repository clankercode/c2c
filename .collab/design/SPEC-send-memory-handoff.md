# SPEC-send-memory-handoff.md

## #286 — Send-Memory Handoff Edge Cases

**Author**: lyra-quill
**Date**: 2026-04-26
**Status**: MCP-only shipped (#286/#327). CLI subcommand `c2c memory send` deferred.

> **Shipped surface (2026-04-28)**: The send-memory handoff is implemented as
> the MCP `send_memory` tool, auto-triggered when `mcp__c2c__memory_write` is
> called with `shared_with: [aliases]`. Recipients receive an auto-DM
> referencing the granted entry. See #286 (handoff) and #327 (broker.log
> diagnostic for every send-memory attempt).
>
> The standalone `c2c memory send` CLI proposed below is **deferred** —
> `memory_group` in `ocaml/cli/c2c_memory.ml` currently exposes only
> `list/read/write/delete/grant/revoke/share/unshare`. Re-open this spec when
> picking up the CLI slice.

---

## Problem

Per-agent memory now supports private, global shared, and targeted
`shared_with` reads. That is enough for an agent to prepare a durable note for
another local agent, but the actual handoff still has friction:

1. The sender must know whether to write a new entry or grant an existing one.
2. The sender must separately notify the recipient.
3. Failure modes are unclear: missing recipient, offline recipient, remote
   alias, relay outage, or multi-recipient partial failure.

`send-memory` should be the safe, explicit handoff wrapper around those steps.

---

## Goals

- Make one-agent-to-another memory handoff a single command/tool call.
- Preserve the memory privacy model: private by default, targeted grants only
  when explicitly sending.
- Return actionable per-recipient results instead of silent success.
- Work for local recipients now without blocking future remote transport.
- Avoid pretending that a targeted local memory grant is readable by a remote
  machine.

---

## Non-Goals

- No remote memory synchronization in v1.
- No guaranteed delivery receipt; c2c message delivery remains best-effort.
- No revocation of already-sent snapshots. Revocation only blocks future
  guarded memory reads.
- No automatic batch rollback. If one recipient succeeds and another fails, the
  command reports partial success.

---

## Proposed CLI

> **Deferred**: The CLI subcommand below is design-only as of 2026-04-28; the
> shipped surface is the MCP `send_memory` tool, auto-triggered when
> `mcp__c2c__memory_write` is called with `shared_with`. See #286/#327.
>
> **Why MCP-only shipped first?** The MCP path covers the in-session use case
> directly (an agent writing a memory for a peer is already in an MCP-capable
> turn). The CLI surface is operator/script value-add for cross-session bulk
> operations and remote `alias@host` targets, neither of which are on the
> critical path yet.

```bash
c2c memory send <name> --to ALIAS[,ALIAS...] [--message TEXT] [--json]
c2c memory send <name> --to ALIAS --mode auto|grant-reference|snapshot|no-grant
c2c memory send <name> --to ALIAS --snapshot [--message TEXT] [--json]
c2c memory send <name> --to ALIAS --no-grant [--message TEXT] [--json]
```

Default mode is `auto`: grant-reference for local aliases and snapshot for
remote aliases. `--snapshot` and `--no-grant` are aliases for
`--mode snapshot` and `--mode no-grant`.

### Mode Semantics

`--grant-reference`:

- Requires a local alias, not `alias@host`.
- Adds the recipient to `shared_with` for the sender's existing memory entry.
- Sends a DM containing a reference:
  `c2c memory read <name> --alias <sender>`.
- Best for same-repo agents because the recipient reads the durable source.

`--snapshot`:

- Sends the memory body in the DM.
- Does not mutate `shared_with`.
- Required for remote `alias@host` recipients in v1 because remote machines do
  not share the sender's `.c2c/memory/<alias>/` directory.
- Warning text must state that snapshot revocation is impossible once sent.

`--no-grant`:

- Sends only a notification/reference and does not mutate `shared_with`.
- Fails unless the recipient can already read the entry via `shared:true` or an
  existing `shared_with` grant.
- Useful when the sender wants to avoid widening access accidentally.

---

## Recipient Resolution

### Local Alias

For `ALIAS` without `@`:

1. Resolve against broker registrations by alias.
2. If no registration exists, exit non-zero with:
   `recipient_not_found`.
3. If a registration exists but is not currently live, do not fail solely for
   liveness. The message can still enqueue to the broker inbox/archive path.
   Return `queued_offline`.
4. If enqueue fails, exit non-zero with `enqueue_failed`.

This avoids silent handoffs to typos while still allowing handoff to sleeping
or temporarily offline known agents.

### Remote Alias

For `ALIAS@HOST`:

1. Treat as remote by syntax; do not require a local registration.
2. Default to `--snapshot`; reject `--grant-reference` with
   `remote_reference_unsupported`.
3. Append the DM to `remote-outbox.jsonl` through the existing remote send path.
4. If append succeeds, return `queued_remote`, even if the relay connector is
   not currently running.
5. If appending to the remote outbox fails, exit non-zero with
   `remote_outbox_failed`.

The command must not claim delivered status for remote aliases. Relay
forwarding is asynchronous.

---

## Batch Sends

`--to` accepts a comma-separated list. The command processes recipients in the
provided order and returns per-recipient results.

Plain text should be concise:

```text
sent memory handoff: handoff-note
  bob: granted + queued
  carol: queued_offline
  dana@relay.c2c.im: queued_remote snapshot
  typo: recipient_not_found
```

JSON shape:

```json
{
  "name": "handoff-note",
  "sender": "alice",
  "ok": false,
  "results": [
    {"recipient": "bob", "mode": "grant-reference", "status": "queued"},
    {"recipient": "carol", "mode": "grant-reference", "status": "queued_offline"},
    {"recipient": "dana@relay.c2c.im", "mode": "snapshot", "status": "queued_remote"},
    {"recipient": "typo", "mode": "grant-reference", "status": "recipient_not_found"}
  ]
}
```

Exit code:

- `0` when every recipient reaches a queued status.
- `1` when any recipient fails.
- Successful recipients are not rolled back after a later failure.

---

## Message Format

Reference DM:

```text
alice shared memory with you: handoff-note

Read it with:
  c2c memory read handoff-note --alias alice

Optional note:
  <message>
```

Snapshot DM:

```text
alice sent a memory snapshot: handoff-note

<body>

Optional note:
  <message>

Snapshot caveat: revocation cannot erase content already sent.
```

Messages should be plain text for maximum cross-client readability.

---

## MCP Surface

Add `memory_send` after CLI semantics are stable:

```json
{
  "name": "handoff-note",
  "to": ["bob", "dana@relay.c2c.im"],
  "message": "Use this for the review context.",
  "mode": "auto"
}
```

`mode` values:

- `auto`: local aliases use grant-reference, remote aliases use snapshot.
- `grant-reference`: fail on remote aliases.
- `snapshot`: never mutates `shared_with`.
- `no-grant`: only notify if already readable.

The MCP result should use the same JSON shape as the CLI `--json` output.

---

## Implementation Slices

### Slice 1 — Local CLI

- Add `c2c memory send`.
- Support local aliases only.
- Implement `grant-reference`, `no-grant`, per-recipient JSON, and tests for:
  - missing recipient fails;
  - offline-but-known recipient queues;
  - batch partial failure exits non-zero;
  - `--no-grant` refuses unreadable private entries.

### Slice 2 — Remote Snapshot

- Add remote `alias@host` support.
- Default remote recipients to snapshot mode.
- Test remote outbox append success/failure without a live relay.
- Document that remote queued is not delivered.

### Slice 3 — MCP Parity

- Add `memory_send` MCP tool.
- Reuse the CLI/core helper rather than duplicating memory parsing and enqueue
  logic.
- Add MCP tests for local grant-reference and remote snapshot JSON results.

---

## Open Questions

1. Should `--snapshot` require an explicit confirmation flag for local aliases
   to reduce accidental content leakage, or is the mode name clear enough?
2. Should local unknown aliases support `--force-unknown` for pre-registering a
   future recipient, or should typo prevention remain strict in v1?
3. Should successful grants be rolled back when the subsequent DM enqueue fails?
   Current recommendation: no automatic rollback; report the failure and let the
   sender revoke if needed.
