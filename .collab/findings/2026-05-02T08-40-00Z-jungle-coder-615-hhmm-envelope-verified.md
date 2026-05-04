# #615 HH:MM in transcript envelope — VERIFIED (no bug)

**Filed by:** jungle-coder
**Date:** 2026-05-02
**Severity:** N/A — not a bug; feature verified working
**Status:** CLOSED — no action needed

## Summary
Feature request #615 asked for `ts="HH:MM"` in the transcript c2c envelope.
Verification confirms the code path is correct end-to-end.

## Code Path Verified

### 1. Timestamp generation (`c2c_mcp_helpers.ml:523-525`)
```ocaml
let format_ts_hhmm (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min
```
Converts Unix float timestamp → `"HH:MM"` UTC string.

### 2. ts_attr in envelope (`c2c_mcp_helpers.ml:536-538`)
```ocaml
let ts_attr = match ts with
  | Some t -> Printf.sprintf " ts=\"%s\"" (format_ts_hhmm t)
  | None -> ""
```
Formats as `ts="HH:MM"` XML attribute.

### 3. format_c2c_envelope uses ts_attr (`c2c_mcp_helpers.ml:542,548`)
```ocaml
Printf.sprintf
  "<c2c event=\"message\" from=\"%s\" to=\"%s\" source=\"broker\" reply_via=\"%s\" action_after=\"continue\"%s%s%s>\n%s\n</c2c>"
  ... role_attr tag_attr ts_attr content
```

### 4. Hook passes m.ts through (`c2c_inbox_hook.ml:267`)
```ocaml
C2c_mcp.format_c2c_envelope
  ... ~ts:m.ts ~content:m.content ()
```

## Python Reference Parity
Python reference impl (`format_c2c_envelope` in `c2c_kimi_wire_bridge.py`):
```python
ts_attr = f' ts="{ts}"' if ts else ''
# → <c2c event="message" from="jungle-coder" to="jungle-coder" source="broker" reply_via="c2c_send" action_after="continue" ts="14:30">
```

OCaml and Python produce identical envelope output for the ts attribute.

## Note
- ts is in UTC (Unix.gmtime), not local timezone
- ts is optional — if `m.ts` is not set, no `ts=` attribute appears
- `source="broker"` attribute present (not `alias=`)

## Resolution
No fix needed. Feature is correctly implemented. Closing.