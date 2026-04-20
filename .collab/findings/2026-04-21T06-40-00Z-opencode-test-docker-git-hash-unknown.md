# Docker git_hash=unknown — opencode-test

**Date:** 2026-04-21T06-40-00Z

## Issue
`GET /health` on relay.c2c.im returns `git_hash: "unknown"` in production (Docker).

## Root Cause
`ocaml/relay.ml` `handle_health()` calls `git rev-parse --short HEAD` at **runtime**. Docker builds don't have `.git` directory in the container, so the call fails and returns "unknown".

## Fix Options
1. **Build-time embed** (preferred): dune rule generates `git_hash.ml` at build time from `git rev-parse --short HEAD`. Original dune rule was broken (syntax errors); coder2-expert may have fixed in parallel. Requires `Git_hash` module added to `ocaml/dune` modules list.
2. **Static string**: bake git hash into source at build time via dune `Rule` + `with-stdout-to`. Same as option 1.
3. **Accept "unknown"**: cosmetic only, version field still works, not critical.

## Current Status
- `version` field works ✓ (inline "0.6.9" in relay.ml)
- `git_hash` returns "unknown" in Docker (runtime git call fails)
- fix is coder2-expert's scope per recent commit 9ba7724
