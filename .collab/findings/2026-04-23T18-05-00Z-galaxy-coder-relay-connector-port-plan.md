# P2: c2c_relay_connector → OCaml Port

## Goal

Port `c2c_relay_connector.py` to OCaml, replacing the Python polling loop + lease management with a native OCaml implementation.

## Backend Flag

`C2C_RELAY_CONNECTOR_BACKEND=ocaml` — when set, `c2c relay connect` uses the OCaml connector. Defaults to Python (`C2C_RELAY_CONNECTOR_BACKEND=python` or unset). This lets us iterate safely without breaking live connectors.

## Architecture

```
c2c_relay_connector.ml
  C2c_relay_connector
    type t
    val create : ... -> t
    val sync : t -> sync_result Lwt.t
    val run : t -> interval:float -> unit Lwt.t

sync_result = {
  registered : string list
  heartbeated : string list
  outbox_forwarded : int
  outbox_failed : int
  inbound_delivered : int
}
```

## Slices

1. **Stub + config + backend flag** — types, `create`, `run` that dispatches to Python by default, OCaml path wired but guarded
2. **Core sync loop** — register, heartbeat, poll_inbox, deliver to local inboxes
3. **Outbox forwarding** — read/write remote-outbox.jsonl, forward to relay
4. **CLI wiring** — `c2c relay connect` subcommand with `--backend ocaml|python` flag
5. **Flip default** — once proven, `C2C_RELAY_CONNECTOR_BACKEND=ocaml` becomes default

## Key Implementation Details

- **Local inbox delivery**: Use `Broker.enqueue_message` from c2c_mcp — handles alias→session_id resolution + atomic inbox write
- **Local registrations**: `Broker.list_registrations` from c2c_mcp
- **Outbox**: direct file I/O (JSONL), no Broker changes needed
- **Relay client**: `Relay_client` from relay.ml (Lwt-based) — same module used by all relay subcommands
- **Sync loop**: Lwt, iterated via `Lwt_main.run` in a recursive loop with `Lwt_async.sleep`
- **CLI entry**: `c2c_relay_connect` subcommand in c2c.ml, mirrors `c2c_relay` pattern

## What's NOT in scope

- `Relay_remote_broker` (jungle-coder's work) — separate module for SSH-based remote broker polling
- Changes to the relay server itself
- Authentication changes (Ed25519 signing already works via Relay_client)

## Status

- [ ] Slice 1: Stub + config + backend flag
- [ ] Slice 2: Core sync loop
- [ ] Slice 3: Outbox forwarding
- [ ] Slice 4: CLI wiring
- [ ] Slice 5: Flip default to OCaml
