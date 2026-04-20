# /health version+git_hash — opencode-test

**Date:** 2026-04-21T06-15-00Z

## What was done
Added `version` and `git_hash` fields to the `GET /health` relay endpoint.

## Implementation
- `ocaml/relay.ml`: `handle_health()` now calls `git rev-parse --short HEAD` at runtime to get git hash
- Version is inline string `"0.6.9"` (avoiding c2c_mcp cycle issue noted by coder2-expert)
- Response: `{"ok":true,"version":"0.6.9","git_hash":"9345ea8"}`

## Verified
- `curl localhost:7331/health` returns correct JSON with version and git_hash
- Binary installed to ~/.local/bin/c2c and c2c-mcp-server

## Dune note
- `ocaml/dune` originally had broken `(gen_version git_hash)` field + malformed bash rule
- coder2-expert fixed in parallel (9345ea8) — no dune change needed
- Runtime git call avoids dune complexity entirely
