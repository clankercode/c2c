# #311 MCP Inner/Outer Proxy Split

## Context

The c2c MCP server (`c2c-mcp-server` binary) currently runs as a single monolithic process that handles both:
- JSON-RPC request/response over stdio (Claude Code ↔ broker)
- Background tasks: nudge scheduler, inbox watcher, orphan replay, auto-join rooms

This is fine for the current single-process model, but becomes a problem when we want **restarts without losing registration**. If the MCP server restarts (e.g. after a binary update), it loses its PID registration until the outer loop re-registers it.

## Design

The solution is a two-process model:

```
Slice A (this slice):
  c2c-mcp-server  → standalone binary (full-featured)
  c2c-mcp-inner   → same binary, different role string (installed alongside)
  c2c mcp-inner   → CLI command (Tier4, hidden in agent sessions)

Slice B (follow-up):
  c2c mcp-inner   → outer proxy that spawns c2c-mcp-inner binary
  c2c-mcp-inner   → inner server with full-featured server logic
  On restart: outer exits → inner survives → re-registration is instant
  The inner server provides nudge + inbox watcher + orphan replay.

Slice C (follow-up):
  Health-check + respawn logic in outer proxy
  Graceful handoff of registration from old inner to new inner
```

## Slice A Scope

- Extract `run_inner_server` from `c2c_mcp_server.ml` into `c2c_mcp_server_inner.ml`
- Create `c2c-mcp-inner` binary entry point (`c2c_mcp_server_inner_bin.ml`)
- Add `c2c mcp-inner` CLI command (Tier4)
- Wire `c2c setup install` to install both binaries
- Wire `just install-all` to install both binaries
- Install guard (#302/#322) covers both binaries

## Key Properties

- Both binaries are **identical in behavior** for Slice A — the only difference is the role string in logs
- Broker root resolution is inlined in both binaries (no `C2c_utils` dependency)
- The inner/outer split is invisible to the caller for Slice A

## Acceptance Criteria

See `.collab/design/2026-04-26T10-47-15Z-lyra-quill-311-mcp-inner-outer-proxy.md`
