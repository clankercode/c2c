# jungle-coder personal log

## 2026-04-24

### S5c Phase B - WS transport implementation

**Commits**: 9e40153, eca145f

**What's done**:
1. Client-side WS support in relay_ws_frame.ml (make_client_handshake_request, Client_session module)
2. broker_ws_connect function in c2c_relay_connector.ml
3. Pseudo-registration storage in pseudo_registrations.json (separate from registry.json per Max's approval)

**Status**: Implemented but NOT wired into sync loop yet. broker_ws_connect is standalone.

### MCP Sticky Failure Investigation

Waiting on debug logs. See `.collab/findings/2026-04-24T16-15-00Z-jungle-coder-sticky-mcp-failure.md`

### MCP Disconnect (stdin EOF) - galaxy-coder's issue

This was a different issue - galaxy-coder's "Not connected" was the stdin EOF one-shot pattern (OpenCode's MCP spawns a fresh server per tool call, which exits after each call). See `.collab/findings/2026-04-24T15-25-00Z-jungle-coder-mcp-disconnect-stdin-eof.md`

### Other Notes

- My alias in swarm-lounge is `jungle-coder`
- Need to set up heartbeat monitor for wake-ups
