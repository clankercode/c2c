# Python Relay Module Deprecation Analysis

**Date:** 2026-04-23
**Author:** CEO
**Status:** COMPLETE

## Summary

Six Python relay modules analyzed for migration to OCaml relay (ocaml/relay.ml).

| File | Live Callers | Action |
|------|-------------|--------|
| `c2c_relay_connector.py` | c2c_cli.py dispatch, tests | DEPRECATED (docstring) |
| `c2c_relay_contract.py` | 8 test files | DEPRECATED (docstring) |
| `c2c_relay_rooms.py` | c2c_cli.py dispatch, tests | DEPRECATED (docstring) |
| `c2c_relay_status.py` | c2c_cli.py dispatch, tests | DEPRECATED (docstring) |
| `c2c_relay_config.py` | c2c_cli.py dispatch, c2c_health.py, tests | DEPRECATED (docstring) |
| `c2c_relay_server.py` | c2c_cli.py dispatch, 10 test files | DEPRECATED (docstring) |

## Decision: No Move to deprecated/

All six files have live callers (CLI dispatch + tests). Moving to `deprecated/` would break:
- `c2c_cli.py` relay subcommand dispatch (5 files)
- Test suite (test_relay_*.py, test_c2c_relay_*.py)
- `c2c_health.py` relay config loading

Instead: added `.. deprecated::` docstring header to each file pointing to `ocaml/relay.ml`.

## Next Steps

When OCaml relay is production-complete and all Python relay CLI dispatch is removed:
1. Remove Python relay dispatch from `c2c_cli.py`
2. Retire test files that only test Python relay
3. Move remaining Python relay files to `deprecated/`

## Commits

- `55556b0`: deprecate(c2c_relay_*.py): mark 5 Python relay utilities as deprecated
- `af1b573`: deprecate(c2c_relay_server.py): Python relay server superseded by OCaml relay.ml
