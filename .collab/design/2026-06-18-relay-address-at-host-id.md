# Relay address shape: use `alias@host_id`, not `alias#host_id`

**Date**: 2026-06-18.

**Status**: design delta. Supersedes the relay-alias shape recommendation in
`.collab/design/2026-06-17-c2c-opaque-host-id.md` for new clients. No
backwards-compatibility requirement for `pi-c2c`; older `alias#host_id` users
may be dropped during the extension migration.

## Problem

The previous relay privacy design used `<alias>#<host_id>` as the relay-facing
alias. That overloads `#`:

- local broker room fan-out uses `to_alias = "<recipient-alias>#<room-id>"`;
- existing `canonical_alias` uses `<alias>#<repo>@<host>`;
- the relay workaround used `<alias>#<opaque-host-id>`.

That makes receiver-side classification brittle. A room id such as
`deadbeefcafe` can look exactly like a 12-hex host id unless the client carries
extra source metadata.

## Decision

Use `@` for relay/network qualification:

```text
alias                 local/session broker peer alias
alias#room            broker room delivery tag or canonical alias component
alias@host_id         relay-qualified peer address
alias@relay.c2c.im    relay-qualified peer address when the host part is a relay name/domain
```

For the pi-c2c migration, `host_id` is the same 12-hex opaque host id produced
by `c2c host-id` / the extension's host-id recipe. The user-facing relay
address becomes:

```text
<bare-alias>@<host_id>
```

Example:

```text
pi-c01ea5@3d08761ae3f3
```

## Routing model

Inbound relay messages should preserve a return route distinct from the display
alias:

- display sender: `from_alias = "pi-c01ea5"` when available;
- reply route: `pi-c01ea5@3d08761ae3f3`;
- transport source: `source = "relay"`, `kind = "dm"`.

Clients may learn/cache return routes from inbound relay messages and from
`relay list`. A human or agent can then send to the concrete `alias@host_id`
route without confusing it with room syntax.

## c2c implications

Existing relay code already has `alias@host` parsing (`split_alias_host`,
`host_acceptable`, and `bare_alias` in `ocaml/relay.ml`). This design reuses
that mental model instead of inventing another separator.

The c2c-side follow-up, when desired, is:

- update docs/help that still recommend `<alias>#<host_id>`;
- update opaque-host-id parser tests to prefer `<alias>@<host_id>`;
- make relay registration/list output expose enough metadata for clients to
  derive both display alias and reply route.

This pi-c2c migration does not require c2c to preserve `alias#host_id`.

## pi-c2c migration scope

For `pi-c2c`:

- `deriveRelayAlias(name, hostHash)` returns `${name}@${hostHash}`;
- `parseRelayAlias` parses only `alias@12hex`;
- relay registration uses `alias@hostHash`;
- relay send/poll/list tests and UI expectations use `@hostHash`;
- room detection keeps `#` exclusively for room fan-out, except for historical
  canonical alias text in c2c docs.

No backwards compatibility for `alias#host_id` is required in this migration.

## Acceptance checks

- `deriveRelayAlias("pi-c01ea5", "a1b2c3d4e5f6")` returns
  `pi-c01ea5@a1b2c3d4e5f6`.
- `parseRelayAlias("pi-c01ea5@a1b2c3d4e5f6")` returns
  `{ name: "pi-c01ea5", hostHash: "a1b2c3d4e5f6" }`.
- `parseRelayAlias("pi-c01ea5#a1b2c3d4e5f6")` returns null.
- Relay DMs are classified by explicit relay metadata, not by `#` suffix.
- Broker room delivery tags such as `pi-c01ea5#deadbeefcafe` remain room
  messages.
