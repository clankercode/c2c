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

> Scope note: this page (slice J1) *publishes* the schema and its vectors. The
> individual output surfaces are migrated onto it by later slices (J2 CLI,
> J3 monitor NDJSON, J4 MCP). Until then, existing surfaces keep their current
> shape unchanged.

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
| `delivery.state` | enum `queued` \| `accepted` \| `delivered` | no | Lifecycle state. Unknown value rejected. |

### Reserved for v2 (ignored on parse, never emitted by v1)

| Reserved key | Location | Deferred to |
|---|---|---|
| `identity_pk` | `from` | identity attestation (I003/I008) |
| `verified` | `from` | identity attestation (I003/I008) |
| `trust_tier` | `from` | identity attestation (I003/I008) |
| `priority` | top-level | message prioritization |
| `read` (delivery state) | `delivery.state` value | read receipts (I004) |

Any *other* unknown key at the top level, inside `from`, or inside `delivery`
is also tolerated and ignored (forward-compatibility).

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
  `{queued, accepted, delivered}`; each `source` in `{local, relay}`.

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
