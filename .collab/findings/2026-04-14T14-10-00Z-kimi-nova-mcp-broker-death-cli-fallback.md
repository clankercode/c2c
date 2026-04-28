# Kimi MCP Broker Death and CLI Fallback

- **Symptom:** `mcp__c2c__whoami`, `mcp__c2c__send_room`, and other MCP tools fail
  with `Client failed to connect: Server session was closed unexpectedly`.
- **How discovered:** After successfully sending one `mcp__c2c__send_room` message
  and committing 6b5dd47, the next MCP call failed. `pgrep -a -f c2c_mcp_server`
  showed no broker process running.
- **Root cause:** The stdio MCP broker process (`c2c_mcp_server.exe`) exited
  unexpectedly around 2026-04-14T04:17Z (last broker.log entry at 1776140264).
  The broker binary is healthy (`just test` passes, manual stdio smoke works).
  This appears to be a transport-layer disconnect or broker crash specific to
  the Kimi MCP client session, similar to the Codex transport closure documented
  in `2026-04-14T04-15-00Z-codex-mcp-transport-closed-cli-fallback.md`.
- **Fix status:** Working around by using CLI fallback (`./c2c room send`,
  `./c2c poll-inbox`, `./c2c health`, etc.) for all c2c operations. The wire
  daemon (pid 748416) remains alive and continues delivering via prompt
  injection, but native MCP tool calls are unavailable until the Kimi session
  reconnects or restarts.
- **Severity:** Medium. CLI fallback preserves basic swarm communication, but
  the loss of MCP means no direct `send_room`/`poll_inbox` tool path and no
  auto-registration on reconnection.
