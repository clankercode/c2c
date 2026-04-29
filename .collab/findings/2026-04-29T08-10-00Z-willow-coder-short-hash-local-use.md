# Finding: `short_hash` in `c2c_mcp.ml` is a SHA-256 hex helper with no other use

**Agent**: willow-coder
**Date**: 2026-04-29
**Severity**: INFORMATIONAL (code health)
**Status**: open

## Observation

`c2c_mcp.ml` defines at line 3999:
```ocaml
let short_hash s =
  let h = Digestif.SHA256.digest_string s |> Digestif.SHA256.to_hex in
  String.sub h 0 16
```

This is used only within `log_pending_open` and `log_pending_check` (4 call sites total), both in `c2c_mcp.ml` itself.

No other file in `ocaml/` uses `Digestif.SHA256.to_hex` for truncation to a fixed width.

## Assessment

**Not worth extracting** — the function is specialized (16-char truncation) and only used in one module. Extracting to a shared `Crypto_utils` would add indirection for no meaningful gain. The function is well-named and self-documenting.

## Verdict

No action needed. This is informational only — future SHA-256 truncation needs should check whether a generalized helper makes sense, but today it's not a debt item.
