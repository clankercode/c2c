# Tasks from Max

These are tasks from Max.
When you see a new task here, you should document it in whatever task tracking you have set up.
Statuses: new | before_ingest | ingested | done.
Anything between injested and done should be managed on your end -- you're expected to self organize after all.
When new tasks appear here, or there are tasks that need injesting, they should be broadcast to the swarm so that anyone who is free can pick up the job.

## template
status: new

## opencode plugin for delivery
status: ingested
I believe that opencode plugins should be capable of delivering messages automatically (as user messages at least). ~/src/todoer is such a plugin but the method might not be the best. so we should be sure to research the best way to do this, too. ideally it can be styled differently to a normal user message but that isn't required. doing it with a plugin is a big UX improvement because pty injection doesn't work so well if you're me typing a message to that agent at the time. we should consider this kind of thing for other cli coding clients too if their own featureset is lacking (we should make sure to do comprehensive research on each clients feature set, basically have a whole copy of htier docs in our research folder)
Ingest: broadcast to swarm-lounge by storm-beacon. Research needed: opencode plugin API, plugin types that can inject user messages, todoer example at ~/src/todoer.

## modify c2c xml msg
status: done
The XML msg should include an `action_after="continue"` attribute. it'll just be constant for the moment.
Fix: added `action_after="continue"` to all three envelope builders: c2c_poker.render_payload, claude_send_msg.render_payload, and c2c_poll_inbox.py inline format. Updated exact-match tests in test_c2c_cli.py. 565 Python tests green (storm-beacon, 2026-04-13).

## change of name should update group
status: done
when an agent re-registers to change their name, that should notify people they're connected to.
Fix: OCaml broker (5d65c42) — on re-register with a different alias, broker appends
{"type":"peer_renamed","old_alias":"...","new_alias":"..."} to room history for every room
the session was in. 89 OCaml + 274 Python tests green. kimi renamed to kimi-nova per Max
request — configs updated (run-kimi-inst.d/kimi-nova.json, ~/.kimi/mcp.json).

## post tool hook speed
status: done
the post tool hook call must be super fast, always. it can never hold an agent up
Fix: switched fast-path from $(cat file) to $(<file) (no cat subshell); added `timeout 5` guard on the Python drain invocation so the hook can NEVER block indefinitely. bench-hook (committed) documents baseline: empty/absent/not-configured p99 < 3ms; Python drain ~100ms bounded by timeout. Broadcast to swarm complete.

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
