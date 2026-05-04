# #478 kimi MCP allowedTools — findings

**Date**: 2026-04-30
**Agent**: cedar-coder
**Status**: Fix implemented, committed, verified

## Problem

Managed kimi sessions (via `c2c start kimi`) did not include an explicit
`allowedTools` field in the per-session MCP config written at:

```
~/.local/share/c2c/instances/<name>/kimi-mcp.json
  → passed via --mcp-config-file to kimi-cli
```

Without `allowedTools`, kimi presents all MCP tools to the AI for approval.
c2c's 31 MCP tools (`mcp__c2c__*`) triggered permission prompts on first use
in managed kimi sessions.

## Solution

Added explicit `allowedTools` list to `build_kimi_mcp_config` in
`c2c_start.ml`. The field enumerates all 31 c2c MCP tools by name, so kimi
knows which tools are available and can apply its `auto_approve_actions`
policy correctly.

## Key Finding: Two Separate Mechanisms

1. **`allowedTools`** (this fix): restricts *which tools are presented* to the AI.
   Valid JSON array of tool names. Supported by kimi's MCP config format.

2. **`auto_approve_actions`** (per-session `state.json`): controls *silent
   execution*. Matches on action CONTENT STRING, not tool name. Kimi's
   `state.json` at `~/.kimi/sessions/<uuid>/state.json` contains:
   ```json
   { "approval": { "yolo": true, "auto_approve_actions": [...] } }
   ```
   Default seeded actions: `["run command", "edit file outside of working directory"]`.
   Does NOT automatically include c2c tool actions.

   **Conclusion**: `auto_approve_actions` is a SEPARATE problem (#478 follow-up).
   The current fix (allowedTools) addresses the prompt friction.
   Silent execution without prompts requires additionally seeding
   `auto_approve_actions` with c2c-related action content strings (e.g. "send",
   "poll_inbox") — this is out of scope for this slice but documented for
   future work.

## Verification

- `just check` passes with no new warnings
- `just build` produces clean binary
- Subagent self-review (general agent) confirms:
  - Tool list matches `C2c_mcp.base_tool_definitions` exactly (31 tools)
  - `allowedTools` is valid Yojson
  - No regressions
- Live config generation verified via `c2c start --dry-run` equivalent
  in tmux — generated config contains `"allowedTools"` with all 31 tool names

## Resolution

Both commits landed on `origin/master`:
- `17117066` — build_kimi_mcp_config: session-level kimi-mcp.json with allowedTools
- `dcc3224c` — setup_kimi: global ~/.kimi/mcp.json with allowedTools

Coordinator noted a cherry-pick range bug (order reversed in master log) but both applied cleanly. Build + install green.

## Future Work

- Verify whether `yolo: true` in `state.json` actually suppresses MCP tool
  prompts or only native kimi actions
- If MCP tools need separate allowlist: seed `auto_approve_actions` with
  c2c action content strings (e.g. "send", "poll_inbox", "join_room")
  in the same `state.json` seeding block at lines 4006-4013
- Investigate whether `kimi_wire` mode changes the approval model vs PTY
