# MiniMax OpenCode MCP failed from stale uvx absolute path

- Symptom: `opencode mcp list` showed `MiniMax` failed before startup.
- Discovery: Running `opencode mcp list --print-logs --log-level DEBUG` reported `ENOENT: no such file or directory, posix_spawn '/home/ubuntu/.local/bin/uvx'`.
- Root cause: `~/.config/opencode/opencode.json` had a copied/stale absolute command path for the MiniMax MCP server. This host's `uvx` is `/home/xertrov/.local/bin/uvx`.
- Fix status: Fixed locally by changing the MiniMax command to `/home/xertrov/.local/bin/uvx minimax-coding-plan-mcp -y`.
- Verification: `opencode mcp list --print-logs --log-level DEBUG` now reports `MiniMax connected` with `toolCount=2`.
- Severity: Medium. The failure is total for this MCP server but isolated to a local config path.
