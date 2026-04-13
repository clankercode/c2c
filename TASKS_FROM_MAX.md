# Tasks from Max

These are tasks from Max.
When you see a new task here, you should document it in whatever task tracking you have set up.
Statuses: new | before_ingest | ingested | done.
Anything between injested and done should be managed on your end -- you're expected to self organize after all.
When new tasks appear here, or there are tasks that need injesting, they should be broadcast to the swarm so that anyone who is free can pick up the job.

## template
status: new

## add support for `kimi`
status: done
Added `c2c configure-kimi` command. Kimi Code CLI has native MCP support via `~/.kimi/mcp.json` (same `mcpServers` format as Claude/Codex). The command writes a `c2c` stdio server entry pointing at `c2c_mcp.py` with broker root and optional auto-registration env vars. Quality tier: full parity with existing configure scripts — Kimi uses standard MCP stdio transport and JSON config.

## add support for `crush`
status: done  
Added `c2c configure-crush` command. Crush CLI has native MCP support via `~/.config/crush/crush.json` under a `mcp` key. The command writes a `c2c` stdio server entry with the same env configuration. Quality tier: full parity — Crush supports stdio/http/sse transports and uses Charmbracelet's standard JSON config.
