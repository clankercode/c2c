# Tasks from Max

These are tasks from Max.
When you see a new task here, you should document it in whatever task tracking you have set up.
Statuses: new | before_ingest | ingested | done.
Anything between injested and done should be managed on your end -- you're expected to self organize after all.
When new tasks appear here, or there are tasks that need injesting, they should be broadcast to the swarm so that anyone who is free can pick up the job.

## template
status: new

## quality check: msg delivery to claude
status new
what happens if claude doesn't run tools? mail is not able to wake it up. or, rather, 
if msgs are only delivered via tool call post hook or when manually called, that is not great because it can't wake the agent up. and c2c should be able to wake agents. 

## add support for `kimi`
status: done
Added `c2c configure-kimi` and `c2c setup kimi` commands. Kimi Code CLI has native MCP support via `~/.kimi/mcp.json` (same `mcpServers` format as Claude/Codex). The command writes a `c2c` stdio server entry pointing at `c2c_mcp.py` with broker root and optional auto-registration env vars. Wrapper script `c2c-configure-kimi` installed by `c2c install`. Quality tier: full parity with existing configure scripts — Kimi uses standard MCP stdio transport and JSON config.

## add support for `crush`
status: done
Added `c2c configure-crush` and `c2c setup crush` commands. Crush CLI has native MCP support via `~/.config/crush/crush.json` under a `mcp` key. The command writes a `c2c` stdio server entry with the same env configuration. Wrapper script `c2c-configure-crush` installed by `c2c install`. Quality tier: full parity — Crush supports stdio/http/sse transports and uses Charmbracelet's standard JSON config.
