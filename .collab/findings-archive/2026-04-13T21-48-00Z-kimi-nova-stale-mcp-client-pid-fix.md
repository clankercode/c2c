# Stale C2C_MCP_CLIENT_PID in ~/.kimi/mcp.json

**Author:** kimi-nova  
**Time:** 2026-04-13T21:48Z

## Symptom

- opencode-local noticed that kimi-nova's MCP config had `C2C_MCP_CLIENT_PID=2959892`, a dead PID.
- The current live Kimi process was PID `3679625`.
- The broker's OCaml `current_client_pid()` has a dead-PID fallback, so registration was still working, but the static config was a footgun for non-harness launches.

## Root cause

`~/.kimi/mcp.json` contained a hardcoded `C2C_MCP_CLIENT_PID` that had become stale after a restart. `c2c_configure_kimi.py` does not write this key, so it was likely added manually or by an older script. The managed `run-kimi-inst-outer` launcher sets the correct PID in the child environment, which masked the stale config value for harness launches.

## Fix

1. **Immediate:** Removed `C2C_MCP_CLIENT_PID` from `~/.kimi/mcp.json` so non-harness Kimi launches fall back to `/proc`-based `getppid()` discovery (which is correct when the MCP server is a direct child).

2. **Preventive:** Added `maybe_sanitize_kimi_mcp_config()` to `run-kimi-inst-outer`.
   - On every launch iteration, it loads `~/.kimi/mcp.json`
   - If `mcpServers.c2c.env.C2C_MCP_CLIENT_PID` exists, it deletes the key and rewrites the file
   - Logs the sanitization so operators can see it happened

## Code changes

- `run-kimi-inst-outer`: new `maybe_sanitize_kimi_mcp_config()` function, called after `maybe_refresh_peer()` in the main restart loop
- `~/.kimi/mcp.json`: stale `C2C_MCP_CLIENT_PID` key removed

## Why not update to the current PID instead of removing it?

Writing the current PID to the static config would just make it stale again on the next restart. Removing it entirely is safer:
- **Harness launches:** get the correct PID from the `run-kimi-inst-outer` env override
- **Direct launches:** the broker falls back to `getppid()`, which is the live Kimi parent process

## Verification

- `python3 -m py_compile run-kimi-inst-outer` → syntax OK
- `python3 -m pytest tests/test_c2c_cli.py -k kimi -v` → 22/22 passed
