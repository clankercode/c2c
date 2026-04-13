# Tasks from Max

These are tasks from Max.
When you see a new task here, you should document it in whatever task tracking you have set up.
Statuses: new | before_ingest | ingested | done.
Anything between injested and done should be managed on your end -- you're expected to self organize after all.
When new tasks appear here, or there are tasks that need injesting, they should be broadcast to the swarm so that anyone who is free can pick up the job.

## template
status: new

## change of name should update group
status: ingested
when an agent re-registers to change their name, that should notify people they're connected to.
Plan: on re-register with a different alias, broker should fan out a "peer renamed" notification
to all rooms the session is currently in. Needs OCaml broker change + room membership lookup.
Broadcast to swarm for implementation. Also: kimi renamed to kimi-nova per Max request — configs
updated (run-kimi-inst.d/kimi-nova.json, ~/.kimi/mcp.json).

## post tool hook speed
status: ingested
the post tool hook call must be super fast, always. it can never hold an agent up
Fix: switched fast-path from $(cat file) to $(<file) (no cat subshell); added `timeout 5` guard on the Python drain invocation so the hook can NEVER block indefinitely. Committed in hook update. Broadcast to swarm for any further perf audit needed.

## quality check: msg delivery to claude
status: done
what happens if claude doesn't run tools? mail is not able to wake it up. or, rather, 
if msgs are only delivered via tool call post hook or when manually called, that is not great because it can't wake the agent up. and c2c should be able to wake agents. 
we need to research such a thing and implement it if possible. contact max via attn if we find it's not possible. 
Fix: implemented c2c_claude_wake_daemon.py (commit 1747705). The daemon watches the session inbox with inotifywait and PTY-injects a wake prompt that causes Claude Code to call mcp__c2c__poll_inbox. Installed as c2c-claude-wake. Remaining gap: background managed sessions (no PTY) rely on poll_inbox being in the startup prompt (already present in run-claude-inst configs).

## add support for `kimi`
status: done
Added `c2c configure-kimi` and `c2c setup kimi` commands. Kimi Code CLI has native MCP support via `~/.kimi/mcp.json` (same `mcpServers` format as Claude/Codex). The command writes a `c2c` stdio server entry pointing at `c2c_mcp.py` with broker root and optional auto-registration env vars. Wrapper script `c2c-configure-kimi` installed by `c2c install`. Quality tier: full parity with existing configure scripts — Kimi uses standard MCP stdio transport and JSON config.

## add support for `crush`
status: done
Added `c2c configure-crush` and `c2c setup crush` commands. Crush CLI has native MCP support via `~/.config/crush/crush.json` under a `mcp` key. The command writes a `c2c` stdio server entry with the same env configuration. Wrapper script `c2c-configure-crush` installed by `c2c install`. Quality tier: full parity — Crush supports stdio/http/sse transports and uses Charmbracelet's standard JSON config.
