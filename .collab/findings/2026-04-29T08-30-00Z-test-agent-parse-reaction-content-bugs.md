# Finding: parse_reaction_content had multiple critical bugs

**Date**: 2026-04-29
**Severity**: Critical (blocked peer-PASS)
**Status**: Fixed in `e322940c`

## Root Cause

The original `parse_reaction_content` in `c2c_stickers.ml` had three compounding bugs:

### Bug 1: Prefix check compared 6 chars to a 5-char string
```ocaml
(* WRONG: compares 6 chars to "<c2c " (5 chars) - always true, guard never fires *)
String.sub content 0 6 = "<c2c "
(* FIX: compare 5 chars *)
String.sub content 0 5 = "<c2c "
```

### Bug 2: key_start returned i instead of i+1
```ocaml
(* WRONG: returns i, so key starts one char TOO EARLY (includes leading space) *)
| _ -> i
(* FIX: return i+1 to skip the non-id char *)
| _ -> i + 1
```

### Bug 3: Scanner found `"` first and worked backwards (fundamentally flawed)
The original scanner found quote characters first and tried to work backwards to find the key. This fails for values containing quotes (like `&quot;` entities) because it would try to parse value text as keys.

**Fix**: Rewrite to find `=` first, then scan back for key identifier, forward to find opening `"`, then find closing `"`.

### Bug 4: Test expectation included trailing `"` that shouldn't be there
The hostile note test expected `</c2c> &amp; &lt; &gt; &quot;oops\"` (34 chars) but the correct value is `</c2c> &amp; &lt; &gt; &quot;oops` (33 chars) - the closing `"` is the XML attribute delimiter, not part of the value.

## Symptoms

- All 4 "positive" unit tests failed (well-formed, with note, hostile note, scrambled order)
- 5 "negative" unit tests passed (missing fields, wrong event, etc.)
- Integration tests that checked `string_contains ... "event=\"reaction\""` passed because they never called `parse_reaction_content`

## Detection

The bug was hidden because:
1. The integration tests checked raw archive bytes, not parsed values
2. The unit tests were added in the same commit that introduced the buggy scanner
3. Dune's build cache was returning stale compiled objects, masking source changes

## Lessons

1. **Test the parser in isolation** - standalone ocamlfind compilation revealed the bug when Dune wasn't
2. **Verify test expectations** - the hostile note test expectation was also wrong
3. **Check build cache** - `rm -rf _build` was sometimes needed to force rebuild
