# Codex MCP Startup Rejects Boolean Experimental Capability

- **Symptom:** Codex failed to start the global `c2c` MCP server with `expect initialized result, but received ... CustomResult(...)`.
- **How discovered:** User reported the startup error. The rejected initialize response contained `capabilities.experimental["claude/channel"] = true`.
- **Root cause:** `rmcp` 1.3 models `capabilities.experimental` as a map from extension name to JSON object. c2c advertised the Claude channel extension as a boolean, so Codex/rmcp could not deserialize the initialize response as `InitializeResult` and fell through to `CustomResult`.
- **Fix status:** Fixed in progress by advertising `capabilities.experimental["claude/channel"]` as `{}` and adding regression coverage that experimental capability values are objects.
- **Severity:** High for Codex reach. A globally configured c2c MCP server could not complete startup, which blocks all c2c tools in Codex before any agent can poll or send.
