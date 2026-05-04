# Finding: `tool_ok`/`tool_err` helpers defined but inconsistently used

**Agent**: willow-coder
**Date**: 2026-04-29
**Severity**: MED
**Status**: CLOSED — informational (no bug; migration is optional code health)

## Problem

In `ocaml/c2c_mcp.ml`:
```ocaml
let tool_ok content = tool_result ~content ~is_error:false
let tool_err content = tool_result ~content ~is_error:true
```

These are defined at lines 299-300 but **not exported** in `c2c_mcp.mli`. Call-site usage:

| Pattern | Count |
|---|---|
| `Lwt.return (tool_ok ...)` | 7 |
| `Lwt.return (tool_err ...)` | 4 |
| Raw `tool_result ~content:... ~is_error:...` | 12 |

12 sites use raw `tool_result` instead of the helpers, suggesting the helpers
were added after the handler code was written and migration was never completed.

## Fix sketch

Migrate the 12 raw `tool_result` call sites to use `tool_ok` or `tool_err`.
Net reduction: ~12-24 LOC (each raw call has both `~content:` and `~is_error:`
explicit; the helper encodes the boolean inline).

The `.mli` non-export is intentional (internal helpers) — no change needed there.

## Risk

Low. All 12 raw sites are inside `handle_tool_call` in `c2c_mcp.ml`. No
cross-file callers exist. A quick `dune build` + `just check` after migration
is sufficient validation.
