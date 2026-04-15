# OCaml Relay Module Visibility Issue

**Date**: 2026-04-15
**Status**: WORKAROUND IN PLACE - native relay not yet callable from CLI

## Symptom

`c2c relay serve` falls back to Python relay because `C2c_mcp.Relay_server.start_server` is "Unbound value" at link time in `c2c.ml`, even though:

1. `relay.ml` and `relay_server.ml` are in the dune `modules` list
2. Both `module Relay = Relay` and `module Relay_server = Relay_server` are in `c2c_mcp.ml`
3. The library builds successfully when c2c.ml doesn't reference `C2c_mcp.Relay_server`

## Root Cause Hypothesis

The `Relay` and `Relay_server` modules defined inside `relay.ml` and `relay_server.ml` (not at file level) may not be accessible as `C2c_mcp.Relay` from outside the library due to Dune's module wrapping behavior.

In Dune wrapped libraries, modules are prefixed with `LibraryName__`. The inner modules `RegistrationLease` and `InMemoryRelay` are accessible as `C2c_mcp__.RegistrationLease` but the `Relay` module itself (defined as `module Relay : sig ... end = struct ... end` inside `relay.ml`) might not be re-exported correctly.

## Current State

- `c2c_mcp.ml` has `module Relay = Relay` and `module Relay_server = Relay_server`
- But `c2c_mcp.cmi` does NOT show Relay as a direct sub-module
- When c2c.ml tries to call `C2c_mcp.Relay_server.start_server`, it's unbound

## Workaround

The CLI still falls back to Python relay:
```ocaml
| _ ->
    (* Fall back to Python relay for now *)
    (match find_python_script "c2c_relay_server.py" with ...)
```

## Files Involved

- `ocaml/relay.ml` - defines `RegistrationLease` and `InMemoryRelay` modules (NOT wrapped in another Relay module now)
- `ocaml/relay_server.ml` - defines `Relay_server` with HTTP handlers
- `ocaml/c2c_mcp.ml` - has `module Relay = Relay` and `module Relay_server = Relay_server`
- `ocaml/c2c_mcp.mli` - has `module Relay : module type of Relay` and `module Relay_server : module type of Relay_server`
- `ocaml/dune` - has `(modules c2c_mcp C2c_start Relay Relay_server)`
- `ocaml/cli/c2c.ml` - line 1656 tries to call `C2c_mcp.Relay_server.start_server`

## Next Steps

1. Investigate why `module Relay = Relay` in c2c_mcp.ml doesn't expose Relay at the top level
2. Check if dune's `-open C2c_mcp__` in compilation is causing the issue
3. Consider making `relay.ml` define `module Relay = struct ... end` at file level instead of inline
4. Or use `(wrapped false)` in dune (but Dune docs warn against this)