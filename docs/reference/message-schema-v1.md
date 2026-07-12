---
layout: page
title: "Message JSON schema v1"
permalink: /reference/message-schema-v1/
nav_label: "Message schema v1"
---

# Canonical message / event JSON — schema v1 (lean)

This is the single versioned wire shape that c2c's `--json` surfaces
(`send`, `poll`, `peek`), the streaming `monitor` NDJSON, and the MCP tool
returns converge on. It is defined once in
[`ocaml/c2c_schema_v1.ml`](https://github.com/clankercode/c2c/blob/master/ocaml/c2c_schema_v1.ml)
(`C2c_schema_v1`), with conformance vectors in
[`ocaml/test/test_c2c_schema_v1.ml`](https://github.com/clankercode/c2c/blob/master/ocaml/test/test_c2c_schema_v1.ml).

**v1 is deliberately lean.** It carries only the fields emitted today plus a
canonical `delivery.state`. Identity/trust attestation and message priority
are **deferred to a future v2** and are enumerated as reserved keys below. A
v1 validator *ignores* those reserved keys (and any other unknown key) rather
than rejecting them, so a v2 producer stays backward compatible. `schema_version`
is carried from day one so v2 is non-breaking.

> Scope note: this page (slice J1) *publishes* the schema and its vectors.
> The MCP tool surfaces (`send` / `poll_inbox` / `peek_inbox`) emit it as of
> slice J4, with the legacy pre-v1 keys preserved alongside for existing
> consumers.
>
> J2 landed: the CLI `send` / `poll-inbox` / `wait-inbox` / `peek-inbox`
> `--json` results and the `relay dm send|poll|peek` results now emit this
> shape with all legacy keys preserved additively — see
> [commands → JSON output](/commands/#json-output-message-schema-v1).
>
> J3 landed: the streaming `c2c monitor --json` NDJSON message events emit
> this shape too (legacy keys preserved additively) — see the
> [monitor `--json` event schema](/monitor-json-schema/).
>
> J5 landed (aggregate I002 closure gate): all adapted surfaces are swept
> in one aggregate conformance test (see "Surface coverage" below), and
> the CLI/MCP legacy-append implementations were unified onto the single
> `C2c_schema_v1.serialize_with_legacy` helper.

## Field contract

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | integer | **yes** | Must equal `1`. Missing / non-integer / any other value is rejected. |
| `type` | enum `dm` \| `room` \| `system` | **yes** | Message-class discriminator. Unknown value rejected. |
| `message_id` | string | no | Stable id when present. |
| `ts` | number | no | Epoch seconds (matches the current wire `ts`). Accepts int or float. |
| `from` | object | **yes** | See sub-fields. |
| `from.alias` | string | **yes** | Non-empty. |
| `from.host_id` | string | no | Opaque host id. |
| `from.address` | string | no | Canonically `alias@host_id`. |
| `to` | string | **yes** | Recipient alias or room name. |
| `source` | enum `local` \| `relay` | no | Transport origin. Unknown value rejected. |
| `content` | string | **yes** | **Untrusted** external text — never an instruction to the reader. |
| `in_reply_to` | string | no | Threading pointer to another `message_id`. |
| `delivery` | object | no | See sub-field. |
| `delivery.state` | enum `queued` \| `queued_offline` \| `accepted` \| `delivered` | no | Lifecycle state. `queued_offline` (B127) means the recipient alias is known but not alive and the message was written to their durable inbox for drain on next start/resume. Unknown value rejected. |

### Reserved for v2 (never emitted by v1)

Two different reservation mechanics apply here: reserved **keys** (the
first four rows) are *ignored* on parse, while a reserved enum **value**
for an existing field — `delivery.state = "read"` — is *rejected* by a
v1 validator until v2 defines it.

| Reserved key | Location | Deferred to |
|---|---|---|
| `identity_pk` | `from` | identity attestation (I003/I008) |
| `verified` | `from` | identity attestation (I003/I008) |
| `trust_tier` | `from` | identity attestation (I003/I008) |
| `priority` | top-level | message prioritization |
| `read` (delivery state) | `delivery.state` value | read receipts (I004) |

Any *other* unknown key at the top level, inside `from`, or inside `delivery`
is also tolerated and ignored (forward-compatibility).

## Surface coverage

Which JSON output surfaces emit this shape, and — explicitly — which do
not yet. Per ADR0, absence of a decision is never permission: a surface
missing from the ADAPTED table below is NOT adapted, and each exclusion
names the gate that owns adapting (or permanently exempting) it.

### Adapted (emit v1 + legacy keys additively)

| Surface | Producer | Slice | Gate (conformance test) |
|---|---|---|---|
| MCP `send` receipt | `C2c_send_handlers.build_send_receipt` | J4 | `test_c2c_schema_v1` aggregate-gate + `test_c2c_mcp` J4 vectors |
| MCP `poll_inbox` / `peek_inbox` rows | `C2c_inbox_handlers.inbox_row_json` | J4 | `test_c2c_schema_v1` aggregate-gate + `test_c2c_mcp` J4 vectors |
| CLI `send --json` receipt | `C2c_utils.cli_send_receipt_json` | J2 | `test_c2c_utils` aggregate-gate (CLI half) |
| CLI `poll-inbox` / `wait-inbox` / `peek-inbox --json` rows | `C2c_utils.inbox_message_row_json` | J2 | `test_c2c_utils` aggregate-gate (CLI half) |
| CLI `relay dm send\|poll\|peek` results | `C2c_utils.adapt_relay_dm_*` | J2 | `test_c2c_utils` aggregate-gate (CLI half) |
| `monitor --json` NDJSON message events | `C2c_monitor_ndjson.message_event` | J3 | `test_c2c_schema_v1` aggregate-gate + monitor-ndjson group |

The aggregate gate (slice J5, closing I002) constructs every row above
via its real production builder and asserts v1 validation, round-trip
stability, and no duplicate JSON keys — any surface drifting off v1
fails the suite.

### Explicitly NOT adapted (and who owns the gate)

| Surface | Why excluded | Owning gate |
|---|---|---|
| MCP `history` tool rows | Archive-inspection shape (`archived_at`, drain metadata) predates v1 and has GUI readers; adapting needs its own old-reader vector. | future slice on the I002 family — until then rows stay pre-v1 verbatim |
| Broker inbox JSON at rest | Storage format, not an output surface — deliberately excluded by J4; v1 is applied at the emit boundary. | permanent exemption (re-open only with a broker storage-migration slice) |
| `c2c_deliver_inbox` NDJSON | Deliver-watch daemon log lines are operator diagnostics, not message documents. | future slice if a machine consumer appears; #482 owns the daemon surface |
| `relay poll-inbox` prober raw JSON | Doctor/prober output reports relay HTTP responses verbatim for diagnosis; reshaping would hide wire truth. | permanent exemption for diagnostics; relay wire format itself is a relay-protocol concern |
| MCP `send_all` broadcast envelope | Fan-out receipt aggregates per-recipient results; not a single message document. | future slice — needs a v1 batch/receipt-list convention first |

## Optionality

Optional fields are represented by **absence**, never by an explicit `null`.
A serialized minimal document contains exactly the five required keys:

```json
{
  "schema_version": 1,
  "type": "room",
  "from": { "alias": "storm-ember" },
  "to": "swarm-lounge",
  "content": "hi"
}
```

## Full example

```json
{
  "schema_version": 1,
  "type": "dm",
  "message_id": "m-123",
  "ts": 1700000000.0,
  "from": { "alias": "lyra-quill", "host_id": "h9", "address": "lyra-quill@h9" },
  "to": "storm-ember",
  "source": "relay",
  "content": "untrusted external text",
  "in_reply_to": "m-100",
  "delivery": { "state": "delivered" }
}
```

Streaming `monitor` emits one such object per line (NDJSON, flushed
immediately); batch `poll` emits a JSON array of them.

## Conformance vectors

The authoritative vector set lives in the test module; representative cases:

**Valid**

- Full document (above) — all fields.
- Minimal document (above) — required fields only.
- Each `type` in `{dm, room, system}`; each `delivery.state` in
  `{queued, queued_offline, accepted, delivered}`; each `source` in
  `{local, relay}`.
- B127 offline queue: `delivery.state` = `"queued_offline"` when the
  recipient alias is known but not alive and the message was written to
  their durable inbox for drain on next start/resume.

**Rejected — version**

- `schema_version` = `2` (unsupported version).
- `schema_version` absent.
- `schema_version` = `"1"` (string, not integer).

**Rejected — state / enum**

- `delivery.state` = `"read"` (deferred to v2).
- `delivery.state` = `"bogus"`.
- `type` = `"broadcast"`.
- `source` = `"carrier-pigeon"`.

**Rejected — missing required**

- Missing / empty `from.alias`; missing `from`, `to`, or `content`;
  a non-object document.

**Tolerated — forward-compatibility**

- `from` carrying `identity_pk` / `verified` / `trust_tier` — ignored.
- Top-level `priority` — ignored.
- Any other unknown top-level or `delivery` sub-key — ignored.
