# self-pass-detector bugs — fixed

**Date:** 2026-04-25
**SHA:** fb220de
**File:** `ocaml/c2c_mcp.ml` lines ~2987-3038

## Bug 1: needle not lowercased (CRITICAL)

### Symptom
`check_self_pass_content` unit tests 155 (self_violation) and 158 (case_insensitive) FAIL despite the code looking correct.

### Root Cause
```ocaml
let needle = "peer-PASS by" in  (* mixed case *)
let lc = String.lowercase_ascii content in
(* ... *)
String.sub lc i needle_len = needle  (* compares lowercase content to mixed-case needle — ALWAYS FAILS *)
```

`needle.[0]` = `'P'`, but `lc` (lowercase content) only contains `'p'`. The `index_from_opt` search finds the position correctly, but the substring match always fails.

### Fix
```ocaml
let needle = String.lowercase_ascii "peer-PASS by" in  (* now "peer-pass by" *)
```

## Bug 2: extract_alias_after_peer_pass didn't skip whitespace (CRITICAL)

### Symptom
After Bug 1 was fixed, tests still fail because `extract_alias_after_peer_pass` returns empty alias.

### Root Cause
```ocaml
match extract_alias_after_peer_pass content (i + needle_len) with
| Some (claimed_alias, _) -> ...
```

When `i=0` and `needle="peer-pass by"` (12 chars), `i + needle_len = 12`. `content.[12]` = `' '` (the space after "by"). `read_alias "" 12` immediately hits the space and returns `Some ("", 12)` — empty alias.

### Fix
Added `skip_whitespace` helper that advances past space/tab/newline before reading alias characters:
```ocaml
let rec skip_whitespace i =
  if i >= len then None
  else let c = content.[i] in
       if c = ' ' || c = '\n' || c = '\t' || c = '\r' || c = '.' || c = ',' || c = ':'
       then skip_whitespace (i + 1) else Some i
in
match skip_whitespace start_pos with
| None -> None
| Some pos -> read_alias "" pos
```

## Verification
Both bugs traced using `opam exec -- ocaml` REPL to confirm exact byte-level behavior. After both fixes: 179/179 tests pass.
