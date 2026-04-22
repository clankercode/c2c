# Cycle: C2c_start ↔ C2c_mcp re-export

## Root Cause

`c2c_mcp.ml:193` contains:
```ocaml
module C2c_start = C2c_start
```

This re-exports `C2c_start` from within the `c2c_mcp` library.

`C2c_start.start_wire_daemon` (line 1111) currently spawns Python
`c2c_kimi_wire_bridge.py` as a subprocess. To replace with OCaml, it would
call `C2c_wire_daemon.start_daemon` instead.

But: `C2c_wire_daemon → C2c_wire_bridge → C2c_mcp.Broker` (all in the same
`c2c_mcp` library). So wiring `C2c_start` to `C2c_wire_daemon` creates:

```
C2c_start → C2c_wire_daemon → C2c_wire_bridge → C2c_mcp → C2c_start
```

## Evidence C2c_start Does NOT Depend on C2c_mcp

`c2c_start.ml:1257` explicitly avoids `C2c_mcp.Broker`:
```ocaml
(* Clear pid from registration... *)
(* Done inline (not via C2c_mcp.Broker) to avoid a compile-time
   cycle: c2c_mcp.mli re-exports C2c_start, so C2c_start cannot
   depend on C2c_mcp. *)
(try clear_registration_pid ~broker_root ~session_id:name with _ -> ());
```

`C2c_start` has no `C2c_mcp` imports at all.

## Fix Options

### Option A: Remove the re-export (simplest)
Remove `module C2c_start = C2c_start` from `c2c_mcp.ml:193`.
Consumers that need both do `C2c_mcp` and `C2c_start` import them
separately — no cycle since `C2c_start` doesn't depend on `C2c_mcp`.

### Option B: Move C2c_start to a sub-library
Split `C2c_start` (and `C2c_wire_daemon`, `C2c_wire_bridge`) into a
separate `c2c_start` library that `c2c_mcp` can depend on without cycle.

### Option C: Keep Python bridge (status quo)
The Python wire bridge still works. `start_wire_daemon` continues to
spawn the Python subprocess. No OCaml wiring.

## Recommendation

**Option A** is the cleanest for now. Remove the re-export, update any
consumer that was relying on `C2c_mcp.C2c_start` to import `C2c_start`
directly. Since `C2c_start` has zero actual dependencies on `C2c_mcp`,
this is safe.

## Remote Relay Inbox Injection

For the remote relay: the `RELAY` signature (relay.ml:300) exposes
`poll_inbox` and `peek_inbox` but no `insert_inbox`. The inbox insert
logic is tightly coupled inside `send`. Two approaches:

1. **Add `insert_inbox` to RELAY signature**: Add a new method to the
   `RELAY` module type for direct inbox insertion. Implement for both
   `InMemoryRelay` (Hashtbl.replace) and `SqliteRelay` (INSERT statement).

2. **HTTP POST to relay**: For remote relay, inject messages via the HTTP
   `/send` endpoint rather than direct DB insert. The relay's HTTP server
   already handles `send` — just POST to the remote broker's `/send`
   endpoint with the message JSON. This is cleaner for cross-machine
   transport since it uses the existing wire protocol.
