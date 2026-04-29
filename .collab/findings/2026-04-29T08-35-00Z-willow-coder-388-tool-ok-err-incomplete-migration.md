# Finding: #388 audit — `tool_ok`/`tool_err` helpers defined but migration incomplete

**Agent**: willow-coder
**Date**: 2026-04-29
**Severity**: LOW
**Status**: open
**388 item**: first-pass finding #7 (Yojson helpers — but tool_ok/tool_err are JSON-RPC helpers, not Yojson)

## Problem

`c2c_mcp.ml` defines at lines 340-341:
```ocaml
let tool_ok content = tool_result ~content ~is_error:false
let tool_err content = tool_result ~content ~is_error:true
```

These are **internal helpers** (not exported in `c2c_mcp.mli`) that encode the `is_error` boolean inline. Migration state:

| Call pattern | Count |
|---|---|
| `Lwt.return (tool_ok ...)` | 7 |
| `Lwt.return (tool_err ...)` | 4 |
| Raw `tool_result ~content:... ~is_error:(true|false)` | **22** |

22 sites still use the raw `tool_result` with explicit `~is_error:` instead of the cleaner helper.

## Fix shape

Migrate the 22 raw call sites:
```ocaml
Lwt.return (tool_result ~content ~is_error:false)  →  Lwt.return (tool_ok content)
Lwt.return (tool_result ~content ~is_error:true)   →  Lwt.return (tool_err content)
```

**Net LOC reduction**: the raw form is 13 tokens vs 7 for the helper. At 22 sites × 6 fewer tokens = ~132 fewer tokens of boilerplate.

**No behaviour change** — the helpers are pure wrappers.

## Risk

LOW. The helpers are already defined and used in 11 other sites. A simple mechanical substitution. Build + `just check` after migration is sufficient validation.

## `tool_ok`/`tool_err` are correctly NOT exported

The `.mli` not exporting them is correct — they are internal to `handle_tool_call`. If other modules ever need to construct tool results (they don't today), the fix would be to export them. But for now the `.mli` non-export is intentional.
