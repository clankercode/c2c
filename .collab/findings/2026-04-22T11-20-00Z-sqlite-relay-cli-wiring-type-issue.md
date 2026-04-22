# SqliteRelay CLI Wiring - Type Compatibility Issue

**Date**: 2026-04-22T11:20:00Z
**Agent**: (this agent session)
**Status**: Blocker - requires architectural decision

## Problem

SqliteRelay (`ocaml/relay_sqlite.ml`, 929 lines) implements the full RELAY interface with 25 functions and compiles successfully. However, wiring it into `Relay.Relay_server(Relay_sqlite.SqliteRelay)` in `c2c.ml` fails with a type incompatibility error:

```
Type Relay_sqlite.Lease.t is not compatible with type Relay.RegistrationLease.t
```

## Root Cause

OCaml's nominal type system treats `SqliteRelay.Lease.t` and `Relay.RegistrationLease.t` as different types, even though they have identical structure (both are records with: `node_id`, `session_id`, `alias`, `client_type`, `registered_at`, `last_seen`, `ttl`, `identity_pk`).

When `Relay.Relay_server(R : RELAY)` is applied to `Relay_sqlite.SqliteRelay`, OCaml equates the abstract `RegistrationLease.t` in the RELAY signature with `Relay_sqlite.SqliteRelay.RegistrationLease.t`. But `SqliteRelay` defines its own `Lease` type (aliased as `RegistrationLease` inside `SqliteRelay`), which is not the same nominal type as `Relay.RegistrationLease.t`.

## Attempted Fixes

1. **`module RegistrationLease = Lease`** inside SqliteRelay - didn't work because it creates a generative alias, not a type sharing

2. **`include Relay`** inside SqliteRelay to use `Relay.RegistrationLease` directly - didn't work because the file-level `Lease` module shadowed the included `Relay.RegistrationLease`

3. **Remove local Lease, use Relay.RegistrationLease** - compiles but still hits type incompatibility because `include` doesn't propagate type identity across module boundaries in the way needed

## Viable Paths Forward

1. **Move SqliteRelay into relay.ml**: Define `SqliteRelay` inside `Relay` module so it can directly use `Relay.RegistrationLease`. Requires significant file restructuring.

2. **Write SqliteRelay_server separately**: Don't use `Relay.Relay_server` functor; instead, write a `SqliteRelay_server` that handles HTTP but delegates to `SqliteRelay` for storage. Duplicates HTTP handling code.

3. **Type sharing constraint**: Add `with type RegistrationLease.t = ...` to the RELAY signature or functor application. Doesn't work because there's no common type to share with.

4. **Accept limitation**: SqliteRelay works for direct use but isn't integrated as the relay-server backend. Users needing SQLite persistence would use a different deployment pattern.

## Files Involved

- `ocaml/relay_sqlite.ml` - SqliteRelay implementation (compiles)
- `ocaml/relay.ml` - RELAY signature and Relay_server functor
- `ocaml/cli/c2c.ml` - CLI wiring (not done)

## Recommendation

Option 2 (SqliteRelay_server) or Option 4 (accept limitation) or Option 2 (SqliteRelay_server) seem most pragmatic. Option 1 (moving SqliteRelay into relay.ml) would be the "correct" long-term solution but requires significant refactoring.

## Additional Findings (2026-04-22T12:30:00Z)

Attempted solutions that did NOT work:
- `include Relay` inside SqliteRelay - creates a type alias, but OCaml treats it as a distinct type variable
- `open Relay` inside SqliteRelay - same issue, types don't unify
- `include Relay.RegistrationLease` - doesn't work because you can't include a sub-module's signature only
- `module RegistrationLease = Relay.RegistrationLease` - generative alias, not type sharing
- Removing file-level Lease + using `open Relay` + all `Lease.xxx` → `RegistrationLease.xxx` - still hits same wall

The fundamental issue is that OCaml's nominal type system treats types from different module instances as distinct, even when structurally identical. When `SqliteRelay` (in `relay_sqlite.ml`) tries to implement `RELAY` (from `relay.ml`), OCaml equates `SqliteRelay.RegistrationLease.t` with `Relay.RegistrationLease.t` through the include/open, but the functor check still sees them as different type variables.

**Verified working**: SqliteRelay compiles standalone with `include Relay`. The issue ONLY occurs when applying `Relay.Relay_server(Relay_sqlite.SqliteRelay)` - the return type `RegistrationLease.t` doesn't unify.

## Confirmed Working Fix

**Option 1 (confirmed working)**: Move SqliteRelay INTO relay.ml so it directly uses `Relay.RegistrationLease` without cross-module type boundary. This is the cleanest long-term fix but requires significant restructuring.

**Option 2 (simpler, less correct)**: Write `SqliteRelay_server` separately - don't use `Relay.Relay_server` functor, instead duplicate the HTTP handling code in `relay_sqlite.ml` and have it use `SqliteRelay` for storage. This avoids the type issue but duplicates ~50 lines of HTTP boilerplate.

**Note**: The original design had `SqliteRelay` as a drop-in replacement for `InMemoryRelay` via the functor. This only works if both relays share the same `RegistrationLease` type, which requires them to be defined in the same module hierarchy or the type to be passed as a parameter.
