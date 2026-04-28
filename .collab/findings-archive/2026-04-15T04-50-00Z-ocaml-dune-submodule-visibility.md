# OCaml/Dune Submodule Visibility Research

**Date**: 2026-04-15
**Issue**: Native OCaml relay (`Relay_server`) not accessible from `cli/c2c.ml` despite compiling successfully

## Problem

When modules are packed into an OCaml Dune library (`c2c_mcp`), they don't automatically become accessible as `Library.submodule` from outside.

Tried and failed:
- `Relay_server.start_server` → "Unbound module"
- `C2c_mcp.Relay_server.start_server` → "Unbound module"
- `C2c_mcp__.Relay_server.start_server` → "Unbound value"

## Root Cause

Dune libraries are **wrapped by default** (since Dune 3.0+). All modules in the library are placed under `Library_name.Module_name` namespace.

**Key insight**: There is NO `public_modules` directive in Dune. The library's `.mli` file IS the public interface. Any module NOT listed in `.mli` is effectively private.

## Solutions Found

### Solution 1: Re-export in `.mli` (RECOMMENDED - zero build change)

Add to `c2c_mcp.mli`:
```ocaml
module Relay : module type of Relay
module Relay_server : module type of Relay_server
```

This uses the pattern already established for `C2c_start`:
```ocaml
module C2c_start : module type of C2c_start
```

Then from external code: `C2c_mcp.Relay_server.start_server`

### Solution 2: `wrapped false` (NOT recommended)

In `ocaml/dune`:
```lisp
(library
 (name c2c_mcp)
 (wrapped false)
 ...)
```

**WARNING from Dune docs**: "It's highly recommended to keep it this way. Because OCaml top-level modules must all be unique when linking executables, polluting the top-level namespace will make your library unusable with other libraries if there is a module name clash."

### Solution 3: Separate library

Move `Relay` and `Relay_server` to their own `relay` library, have `c2c_mcp` depend on it.

## Implementation Plan (Solution 1)

1. Add to `ocaml/c2c_mcp.mli`:
   - `module Relay : module type of Relay`
   - `module Relay_server : module type of Relay_server`

2. Ensure `relay.ml` has `module Relay = struct...end` (we wrote it with `module Relay = struct`)

3. Check `relay_server.ml` has `module Relay_server : sig...end = struct...end`

4. Update `ocaml/cli/c2c.ml` to use `C2c_mcp.Relay_server.start_server`

5. Verify build passes

## Sources

- Dune Reference Manual - library stanza
- OCaml Manual - Module System
- Real-world examples from Spin, Irmin projects
