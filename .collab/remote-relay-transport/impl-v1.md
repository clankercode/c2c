# Remote Relay Transport v1 — Implementation

**Date**: 2026-04-23
**Owner**: jungle-coder

## Architecture

```
Remote Broker Host          Relay Host              Remote Node (GUI)
+----------------+         +----------------+      +---------------+
| broker_root/   |   SSH   | relay server   | HTTP |              |
| inbox/*.json  | -------> poll + cache   | ------> GET /remote_inbox/<sid>
+----------------+         +----------------+      +---------------+
```

**v1 scope**: One remote broker per relay, polling every 5s via SSH.
Remote inbox is cached in relay's memory and served via `GET /remote_inbox/<session_id>`.

## Components

### 1. `relay_remote_broker.ml` — SSH polling + cache

```ocaml
type remote_broker = {
  id : string;
  ssh_target : string;
  broker_root : string;
}

(* Start polling loop. Returns stop function. *)
val start_polling :
  broker:remote_broker ->
  interval:float ->
  on_fetch:(int -> unit) ->
  (unit -> unit)  (* stop *)

(* Read cached messages for a session *)
val get_messages : session_id:string -> Yojson.Safe.t list
```

### 2. Relay server: `GET /remote_inbox/<session_id>`

New endpoint that returns cached remote inbox messages:
```json
{ "messages": [...] }
```

Requires Bearer token auth if relay has auth enabled.

### 3. CLI: `c2c relay poll-inbox --remote-broker <ssh_target> --broker-root <path>`

Configures a remote broker and starts the polling loop inside the relay server.
Storage: relay persists remote broker config to `relay.json` or similar.

## Implementation Plan

1. `relay_remote_broker.ml`: SSH fetch + in-memory cache (standalone, no RELAY dependency)
2. Relay server: add `GET /remote_inbox/<session_id>` handler (reads from cache)
3. CLI: add `relay poll-inbox` subcommand that configures remote broker and starts polling thread

## Why not POST /inject?

Self-injection via `POST /send` would lose the original `from_alias` — the relay would become the sender. Instead, cache the raw remote inbox and serve it via a separate HTTP endpoint. This preserves the original message envelope.

## Auth

`GET /remote_inbox/<session_id>` requires the same Bearer token as other endpoints.
