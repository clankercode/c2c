# Finding: t_to_json missing signature field

**Date**: 2026-04-25
**Agent**: test-agent
**Severity**: Medium (silent data loss on JSON round-trip)

## Symptom

After signing a peer-PASS artifact, the `c2c peer-pass verify` command returned:
```
VERIFY ERROR: missing signature
```

Even though signing had completed successfully and the artifact file existed.

## Root Cause

`Peer_review.t_to_json` (ocaml/peer_review.ml line 73) did not include the `signature` field in its output, even though the `t` type includes `signature : string`.

The `sign` function creates a signed artifact with `signature` populated, but `t_to_json` silently drops it. So:
1. `sign` returns a `t` with `signature` filled in
2. `t_to_string` (which calls `t_to_json` then `Yojson.Safe.to_string`) produces JSON without `signature`
3. File is written with empty signature
4. On reload, `t_of_json` sees `signature = ""` → `Missing_signature` error

Note: `t_to_canonical_json` correctly handles this by setting `signature = ""` before serialization (the canonical form for signing). But the full artifact JSON stored to disk should include the signature.

## Fix

Added `"signature", `String art.signature` to the `t_to_json` association list.

Fix SHA: `787481c`

## Verification

After fix:
```bash
c2c peer-pass sign 41adae3 --criteria "..." --all-targets --json
# signature field present in output
c2c peer-pass verify .c2c/peer-passes/41adae3-test-agent.json
# VERIFIED: valid signature by test-agent
```

## Lessons

- JSON serialization for storage (with signature) vs signing (without signature) are two different uses — `t_to_json` should serialize everything; `t_to_canonical_json` handles the signing use case
- Should have caught this with a round-trip test: sign → write → read → verify
