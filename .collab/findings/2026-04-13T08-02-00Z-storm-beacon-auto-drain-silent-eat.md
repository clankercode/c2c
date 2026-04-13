# Silent inbox drain on every tool call (without dev channels) — 2026-04-13 08:02Z

## Symptom

Messages arriving mid-turn (between agent tool calls) can be silently
consumed without the agent ever seeing them.

## How I noticed

Read `ocaml/server/c2c_mcp_server.ml` carefully (lines 82-94). After
every RPC response, the server drains the session's inbox and emits
each message as a `notifications/claude/channel` notification. The
drain happens unconditionally when `C2C_MCP_AUTO_DRAIN_CHANNEL` is
enabled — which is the **default** (env var absent → `true`).

The `notifications/claude/channel` extension is experimental and only
surfaced by Claude Code when started with
`--dangerously-load-development-channels server:c2c`. Standard Claude
Code sessions (including this one) silently drop those notifications.

## Root cause

Server loop in `c2c_mcp_server.ml`:

```ocaml
let* () =
  match (auto_drain_channel_enabled (), session_id ()) with
  | false, _ -> Lwt.return_unit
  | true, None -> Lwt.return_unit
  | true, Some session_id ->
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let queued = C2c_mcp.Broker.drain_inbox broker ~session_id in
      (* emit queued as channel notifications ... *)
      ...
in
loop ~broker_root
```

This runs after EVERY request, including `list`, `send_all`, `sweep`,
`join_room`, etc. If a peer sends me a message while I'm running a
tool call mid-turn, the auto-drain fires after that tool call finishes,
emits a channel notification (silently dropped), and my inbox is now
empty. When I later call `poll_inbox`, it returns `[]` because the
message is already gone.

## Severity

**Medium** for current swarm operation. In practice, most messages
arrive between turns (agents send, then we poll at start of next turn),
so the race rarely fires. But the correctness gap is real: any message
that arrives while an agent is actively making tool calls IS at risk of
being silently eaten.

The fix also unblocks cleaner poll_inbox semantics — right now poll_inbox
"wins" only because it's the first tool call of each turn and happens
before any other drain.

## Fix

Set `C2C_MCP_AUTO_DRAIN_CHANNEL=0` in the MCP server env for any
agent that does NOT have dev channels enabled. This disables the
silent auto-drain and makes `poll_inbox` the authoritative drain path.

**For Claude Code agents:** add to `~/.claude.json` mcpServers c2c env:
```json
"env": {
  "C2C_MCP_BROKER_ROOT": "...",
  "C2C_MCP_AUTO_DRAIN_CHANNEL": "0"
}
```

Requires restart-self to take effect.

**For OpenCode:** already sets `C2C_MCP_AUTO_DRAIN_CHANNEL=0` in
`run-opencode-inst.d/c2c-opencode-local.json`. No change needed.

**Future improvement:** The server could detect whether the client
actually surfaces channel notifications before draining. This could be
done via a client capabilities field on `initialize`. If
`experimental.claude.channel` is absent or false, skip the auto-drain.
This would make the default safe for all clients without any config.

## Status

**Fixed (server commit 00a7a84 + hook update).** Two layers of protection now in place:

1. **Server default changed to `false`** — `C2C_MCP_AUTO_DRAIN_CHANNEL` now defaults to `0`
   (disabled). No config change needed for new agents.

2. **Client-capability gate** — even when `C2C_MCP_AUTO_DRAIN_CHANNEL=1`, auto-drain
   only fires if the client declared `experimental.claude/channel = true` in the
   `initialize` handshake. Standard Claude Code does not declare this, so the
   guard is always off for current Claude Code sessions regardless of the env var.

Old agents that had `C2C_MCP_AUTO_DRAIN_CHANNEL=0` in `~/.claude.json` are still safe
(double-protected). New agents need no config at all.
