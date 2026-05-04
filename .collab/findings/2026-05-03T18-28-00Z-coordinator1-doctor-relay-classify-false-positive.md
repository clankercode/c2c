# Finding: doctor relay-critical false positive on S6b MCP server commits

**Date**: 2026-05-03
**Filed by**: willow-coder (per coordinator1 dispatch)
**Status**: Closed (fix landed in master by birch, c46380c3)
**Severity**: Low (cosmetic)

## Symptom

`c2c doctor` flagged commits in the S6b MCP server scheduling slice as
`relay-critical`, suggesting they required a Railway deploy to propagate.
Operators saw a misleading push verdict warning for what were local-only
OCaml changes with no relay impact.

## Root Cause

`c2c doctor` determines relay-critical commits by running:

```bash
git log --oneline origin/master..HEAD | grep -E "ocaml/server/|relay/"
```

The `ocaml/server/` glob was included in the RELAY_CRITICAL pattern as a
heuristic for "things that affect the relay". However, `ocaml/server/`
contains the **MCP server binary** (`c2c_mcp_server.exe`), which is a
client-side delivery mechanism — not the relay itself. S6b MCP server
scheduling commits only touched `ocaml/server/` files, making them
client-side, not relay-critical.

## Fix

birch removed `ocaml/server/` from the RELAY_CRITICAL grep pattern in
commit c46380c3 (`fix(doctor): remove false-positive ocaml/server/ from
relay-critical classify`). The relay itself lives in `ocaml/relay/` and
related paths, not in the server directory.

## Impact

- Cosmetic: `c2c doctor` push verdicts were noisy for S6b slice commits
- No functional impact: the relay was never actually affected by these commits
- Fixed before any mistaken push decisions were made

## Key Lesson

`ocaml/server/` ≠ relay. The server is a client-side binary. Relay impact
is contained in `ocaml/relay/` and any commit that modifies relay mesh
configuration, protocol handling, or relay-side TLS/crypto code.
