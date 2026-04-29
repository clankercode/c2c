# SPEC: forwarder S1 — peer_relays table + identity bootstrap

## Goal

Add the `peer_relays` table to `Relay.t` so S2 can look up peer relay URLs
by name and verify their identity pubkeys on ingress.

## Changes

### 1. `ocaml/relay.ml` — type + interface

Add `peer_relay_t` type and accessors to `RELAY` interface:

```ocaml
type peer_relay_t = { name: string; url: string; identity_pk: string }

val add_peer_relay : t -> peer_relay_t -> unit
val peer_relay_of : t -> name:string -> peer_relay_t option
val peer_relays_list : t -> peer_relay_t list
```

Both `InMemoryRelay` and `SqliteRelay` get a `peer_relays : (string, peer_relay_t) Hashtbl.t`
field (in-memory, populated from CLI flags at boot, not persisted to DB in S1).

### 2. `ocaml/cli/c2c.ml` — CLI flags

Add to `relay_serve_cmd`:
- `--peer-relay name=URL` (repeatable, accumulates `name->url` entries)
- `--peer-relay-pubkey name=PK` (repeatable, accumulates `name->pk` entries)

At boot: validate every name in `--peer-relay-pubkey` also appears in `--peer-relay`,
refuse to start on mismatch.

### 3. `ocaml/relay.ml` — SqliteRelay

`SqliteRelay.create` accepts `?peer_relays:(string, peer_relay_t) Hashtbl.t`.
In-memory table passed in from CLI at boot; not stored in the SQLite DB.

## Acceptance Criteria

- [ ] `InMemoryRelay.create ~peer_relays:(Hashtbl.of_list [...])` populates the table
- [ ] `peer_relay_of r ~name:"relay-b"` returns `Some { url; identity_pk }` when configured
- [ ] `peer_relays_list` returns all configured peers
- [ ] Boot with `--peer-relay relay-b=http://... --peer-relay-pubkey relay-b=BASE64PK` succeeds
- [ ] Boot with `--peer-relay relay-b=http://... --peer-relay-pubkey relay-c=DIFFERENTPK` fails with error
- [ ] Existing tests pass (no regression)
- [ ] Unit test: boot relay with two peers, assert table populated, identity persisted across restart (InMemoryRelay)
