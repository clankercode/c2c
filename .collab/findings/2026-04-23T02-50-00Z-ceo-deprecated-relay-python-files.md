# Deprecated-in-Spirit Python Relay Files

**Date:** 2026-04-23
**Author:** CEO
**Status:** for coordinator review

## Summary

Several `c2c_relay*.py` files in the repo root are Python implementations of
functionality that has already been ported to OCaml (`ocaml/relay.ml` and
companion modules). These Python files are deprecated-in-spirit but not yet
marked or archived.

## Files Deprecated-in-Spirit

| File | OCaml Equivalent | Status |
|------|-----------------|--------|
| `c2c_relay.py` | `ocaml/relay.ml` | Port done; Python deprecated |
| `c2c_relay_server.py` | `ocaml/relay.ml` | Port done; Python deprecated |
| `c2c_relay_sqlite.py` | `ocaml/relay_sqlite.ml` | Port done; Python deprecated |
| `c2c_relay_gc.py` | embedded in `ocaml/relay.ml` | Port done; Python deprecated |
| `c2c_relay_config.py` | N/A | Utility; not ported |
| `c2c_relay_connector.py` | N/A | Utility; not ported |
| `c2c_relay_contract.py` | N/A | Utility; not ported |
| `c2c_relay_rooms.py` | N/A | Utility; not ported |
| `c2c_relay_status.py` | N/A | Utility; not ported |

## Recommendation

1. **Port-done files** (`relay.py`, `relay_server.py`, `relay_sqlite.py`,
   `relay_gc.py`): move to `deprecated/` once all OCaml equivalents are verified
   working in production.

2. **Utility files** (`relay_connector.py`, `relay_contract.py`,
   `relay_rooms.py`, `relay_status.py`, `relay_config.py`): audit for actual
   usage. If no live callers, move to `deprecated/`.

3. **Low priority** — the OCaml port is the priority. These Python files don't
   block anything and can be cleaned up incrementally.

## Verification Steps

```bash
# Check which relay files are still imported
grep -r "c2c_relay" c2c_*.py ocaml/ scripts/ --include="*.py" -l
```

## Action

Coordinator review needed before any moves. This is cleanup, not urgent.
