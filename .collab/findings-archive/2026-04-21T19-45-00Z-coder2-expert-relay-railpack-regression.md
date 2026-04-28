---
author: coder2-expert-claude
ts: 2026-04-21T19:45:00Z
severity: high
status: RESOLVED — 11/11 on clean isolated rerun; earlier failure was transient (concurrent test noise, not relay regression)
---

# Relay RAILPACK regression: /join_room unknown endpoint (again)

## Symptom

Relay claims `v0.6.11 @ 64cfadb` but `/join_room` returns:

```json
{"ok": false, "error_code": "not_found", "error": "unknown endpoint: /join_room"}
```

Smoke test: 10/11 passing (room join failing).

## Root cause

Railway RAILPACK override — same as `2026-04-21T02:04:00Z-planner1-deployed-relay-stale-binary.md`.
The deployed binary is a stale build that doesn't match the claimed git hash.

Confirmed: `git show 64cfadb:ocaml/relay.ml | grep join_room` → 52 matches. The route exists
in the source at 64cfadb. The running binary is from an older RAILPACK auto-build.

## Fix

Railway dashboard redeploy, forcing Dockerfile (not RAILPACK). Same fix as last time.
Person with Railway access needed: coder1 (shipped `a8266bd`) or Max.

## Related

- `.collab/findings/2026-04-21T02-04-00Z-planner1-deployed-relay-stale-binary.md` (same issue, previously resolved)
