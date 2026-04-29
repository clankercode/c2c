# #10: json_util.ml has no from_file wrapper; 26 raw Yojson.Safe.from_file call sites

**Reporter**: cedar-coder (per cairn #388 audit, 2026-04-29)
**Severity**: LOW (code smell — inconsistent access, no behavioural bug)
**Estimate**: MEDIUM (add wrappers + migrate callers) or LOW (add wrappers only, no migration)

## Problem

`ocaml/json_util.ml` provides pure-data JSON accessors (`string_member`,
`int_member`, `assoc_opt`, etc.) but has no `from_file` wrapper. Meanwhile
there are **26 raw `Yojson.Safe.from_file` call sites** across the
codebase, each with ad-hoc error handling:

```ocaml
try Yojson.Safe.from_file path with Yojson.Json_error _ -> default   (* c2c_mcp.ml:548 *)
try Yojson.Safe.from_file path with _ -> `Assoc []                  (* c2c_mcp.ml:1112 *)
try Yojson.Safe.from_file pending_path with _ -> `List []            (* c2c_mcp.ml:2993 *)
let json = Yojson.Safe.from_file config_path in                     (* bare — c2c_mcp.ml:4721 *)
try Some (Yojson.Safe.from_file reg_path) with _ -> None             (* c2c_start.ml:2078 *)
```

Callers span: `c2c_mcp.ml` (4), `c2c_start.ml` (7), `c2c_relay_connector.ml` (4),
`cli/c2c.ml` (7), `cli/c2c_stickers.ml` (3), `peer_review.ml` (1), `relay_nudge.ml` (1).

## Fix

**Phase 1 (XS, done):** Add `from_file` and `from_file_opt` to `json_util.ml`
— committed `bc616fc2`.

```ocaml
val from_file : string -> Yojson.Safe.t
(** raises Yojson.Json_error on parse failure *)

val from_file_opt : string -> Yojson.Safe.t option
(** None on any error — parse error or Sys_error *)
```

**Phase 2 (M):** Migrate raw call sites. At minimum:
- Replace bare `Yojson.Safe.from_file` with `Json_util.from_file`
- Replace `try Some (Yojson.Safe.from_file ...) with _ -> None` with `Json_util.from_file_opt`
- Keep explicit `try ... with Yojson.Json_error _ -> default` wrappers where the
  specific default matters (can't be expressed by `from_file_opt`)

## Status

**Phase 1 FIXED** — `bc616fc2` in `.worktrees/xs-code-health/`.
**Phase 2 open** — 26 call sites remain; estimated MEDIUM if full migration
is required, or LOW if just the wrappers are considered sufficient.
