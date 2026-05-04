# Finding: Yojson.Safe.from_file migration + path constants (code health)

**Date**: 2026-04-29
**Author**: cedar-coder
**Status**: CLOSED — informational, low priority (recommendation: not worth a dedicated slice)

## Context

Willow's `C2c_io.read_json_opt` (#388 code-health audit Finding 3) adds a canonical helper for read+parse JSON. Audit sweep for remaining migration candidates.

## Finding 1: Remaining `Yojson.Safe.from_file` sites

**Severity**: LOW (code health / consistency)
**Category**: deduplication

### Fully migratable (exact `read_json_opt` replacement)

These sites use `try Some (Yojson.Safe.from_file path) with _ -> None` or `try Yojson.Safe.from_file path with _ -> default` — can replace directly with `read_json_opt`:

| File | Line | Pattern | Notes |
|------|------|---------|-------|
| `ocaml/cli/c2c.ml` | 1732 | `try Some (Yojson.Safe.from_file config_path) with _ -> None` | exact |
| `ocaml/c2c_mcp.ml` | 1160 | `try Yojson.Safe.from_file path with Yojson.Json_error _ -> \`Assoc []\`` | could use `Yojson.Json_error` variant or `read_json_opt` |

### Not directly migratable (complex context)

These sites have deeper control flow in try/match blocks; migration requires more refactoring:

| File | Line | Issue |
|------|------|-------|
| `ocaml/cli/c2c_stickers.ml` | 81, 263, 519 | `try let json = Yojson.Safe.from_file ... in match ... with _ -> []` |
| `ocaml/cli/c2c.ml` | 1794, 3557, 7802, 8116 | bare in try/match blocks, complex context |
| `ocaml/cli/c2c.ml` | 3696, 5061, 6459 | try blocks with specific error handling |
| `ocaml/relay_nudge.ml` | 47 | bare in try block |
| `ocaml/c2c_mcp.ml` | 5146 | complex context |
| `ocaml/c2c_start.ml` | 1285, 1330, 1431, 1499, 2078, 2994 | complex try/match blocks |

### Already migrated or canonical

| File | Line | Notes |
|------|------|-------|
| `ocaml/json_util.ml` | 61, 66 | `from_file` / `from_file_opt` canonical wrappers |
| `ocaml/c2c_io.ml` | — | `read_json_opt` canonical helper (willow's Finding 3) |
| `ocaml/c2c_mcp.ml` | 564 | wrapped in specific error handling |

## Finding 2: Repeated path string constants

**Severity**: LOW (maintenance burden)
**Category**: deduplication

Several JSON file paths are constructed inline with `Filename.concat` or `//` rather than centralized:

| Path | Inline construction sites |
|------|-------------------------|
| `registry.json` | `c2c.ml:2851`, `c2c.ml:7728`, `c2c_mcp.ml:557` (`registry_path`), `c2c_relay_connector.ml:77` |
| `pending_permissions.json` | `c2c.ml:7797`, `c2c_mcp.ml:896` |
| `relay_pins.json` | `c2c.ml:6455`, `c2c_mcp.ml:1085` |

These are minor — the patterns are simple and readers can search — but a `C2c_io.json_path t "registry"` helper would deduplicate.

## Recommendation

- Finding 1: **Low priority** — remaining sites are complex enough that migration cost > benefit. Could be revisited as part of a larger refactor.
- Finding 2: **Low priority** — path constants are readable as-is. Not worth a dedicated slice.

## Related

- Willow's Finding 3 (`C2c_io.read_json_opt`) — commit `35335911` on `c2c-io-read-json-opt`
- #388 code-health audit
