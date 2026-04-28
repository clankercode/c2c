# OCaml Relay Module Visibility Issue - RESOLVED

**Date**: 2026-04-15
**Status**: RESOLVED - native OCaml relay server is now working

## Final Solution

The issue was fundamentally about Dune's module wrapping and cross-file module visibility. The solution was to consolidate all relay code into a single file `relay.ml` with nested modules.

### Final Architecture

**`ocaml/relay.ml`** contains:
- `module RegistrationLease` - registration lease handling
- `module InMemoryRelay` - in-memory relay backend
- `module Relay_server` - HTTP server layer

All three modules are nested inside `relay.ml` and exposed via `module Relay = Relay` in `c2c_mcp.ml`.

**`ocaml/c2c_mcp.ml`** re-exports:
```ocaml
module Relay = Relay
```

**`ocaml/c2c_mcp.mli`** exposes:
```ocaml
module Relay : module type of Relay
```

**`ocaml/cli/c2c.ml`** calls:
```ocaml
Lwt_main.run (Relay.Relay_server.start_server ~host ~port ~token ~verbose ~gc_interval ())
```

## Key Files

- `ocaml/relay.ml` - monolithic relay module (RegistrationLease + InMemoryRelay + Relay_server)
- `ocaml/dune` - `(modules c2c_mcp C2c_start Relay)` with `(wrapped false)`
- `ocaml/c2c_mcp.ml` - re-exports `module Relay = Relay`
- `ocaml/c2c_mcp.mli` - `module Relay : module type of Relay`
- `ocaml/cli/c2c.ml` - calls `Relay.Relay_server.start_server`

## What Was Tried

1. Separate files `registrationLease.ml`, `inMemoryRelay.ml`, `relay_server.ml` - failed due to cross-file module visibility issues with Dune wrapping
2. `(wrapped false)` alone didn't solve the cross-file visibility
3. Using `module type of X` in interface files - worked for signatures but didn't solve the visibility issue
4. Creating explicit `.mli` files - created more problems due to module nesting

## What Worked

Consolidating everything into a single `relay.ml` file with nested modules. This avoids all cross-file module visibility issues because all modules are compiled together in the same file.

## Verification

```bash
./ocaml/_build/default/ocaml/cli/c2c.exe relay serve --listen 127.0.0.1:7331 --token test-token &
curl http://127.0.0.1:7331/health  # Returns {"ok":true}
curl -X POST http://127.0.0.1:7331/register -H "Authorization: Bearer test-token" -d '{"node_id":"a","session_id":"s","alias":"x"}'  # Works
curl http://127.0.0.1:7331/list -H "Authorization: Bearer test-token"  # Returns registered peers
```
