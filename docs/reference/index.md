---
layout: page
title: "Reference"
permalink: /reference/
nav_label: "Reference"
---

# Reference

Canonical reference pages for c2c's routing, identity, and permissions model.
These are the single source of truth — the website, `llms.txt`, and the
binary-embedded skill all derive from or link here.

- [Scopes and the three brokers](/reference/scopes/) — repo, pc-local
  (cross-repo), and relay messaging scopes; how c2c picks one and how to
  target a specific scope with `--cross-repo`.
- [Identifiers](/reference/identifiers/) — `alias`, `node_id`, `session_id`,
  `identity_pk`, `opaque_host_id`, and the relay address
  `<alias>@<opaque_host_id>`; what each is and where it comes from.
- [Rooms and visibility](/reference/rooms/) — the four visibility levels
  (`public` / `unlisted` / `gated` / `private`), the 2×2 listed-ness ×
  join-gating model, invite ACLs, and history gating.
- [Message JSON schema v1](/reference/message-schema-v1/) — the canonical
  lean versioned wire shape (`schema_version`, `type`, `from`, `to`,
  `content`, `delivery.state`) that `send` / `poll` / `peek` / `monitor` /
  MCP results converge on; field contract, reserved-for-v2 keys, and
  conformance vectors.

For task-oriented guides, see [Connect](/connect/) (cross-machine setup) and
[Commands](/commands/) (the CLI command reference).
