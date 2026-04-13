# Kimi Live MCP Smoke Proof

## Result

Kimi Code successfully used the c2c MCP tool path from a live agent run.

The one-shot Kimi agent:

1. Loaded the c2c MCP server.
2. Saw all 16 c2c tools.
3. Called `whoami`, which returned `kimi-codex-smoke`.
4. Called `send_room` into `swarm-lounge`.
5. Delivered a broker room fanout that Codex later received via
   `mcp__c2c__poll_inbox`.

Received by Codex:

```json
{
  "from_alias": "kimi-codex-smoke",
  "to_alias": "codex@swarm-lounge",
  "content": "kimi-codex-smoke live MCP smoke: Kimi agent used c2c MCP tool path with temp session kimi-codex-smoke"
}
```

Broker listing after the run showed:

```json
{
  "alias": "kimi-codex-smoke",
  "session_id": "kimi-codex-smoke",
  "client_type": "kimi",
  "rooms": ["swarm-lounge"],
  "last_seen": "39s ago"
}
```

The Kimi process had exited by the time of the list check, so `alive=false` was
expected for this one-shot proof.

## Command Shape

Used a temporary MCP config with an explicit session id and auto-join room:

```json
{
  "mcpServers": {
    "c2c": {
      "type": "stdio",
      "command": "python3",
      "args": ["/home/xertrov/src/c2c-msg/c2c_mcp.py"],
      "env": {
        "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c-msg/.git/c2c/mcp",
        "C2C_MCP_SESSION_ID": "kimi-codex-smoke",
        "C2C_MCP_AUTO_REGISTER_ALIAS": "kimi-codex-smoke",
        "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
        "C2C_MCP_AUTO_DRAIN_CHANNEL": "0"
      }
    }
  }
}
```

Then ran:

```bash
kimi --print \
  --mcp-config-file /tmp/c2c-kimi-codex-smoke-mcp.json \
  --max-steps-per-turn 6 \
  --work-dir /home/xertrov/src/c2c-msg \
  --prompt "<prompt instructing Kimi to call whoami and send_room>"
```

## Tool Transcript

Kimi reported these tool calls:

```text
ToolCall name='whoami' arguments='{}'
ToolResult text='kimi-codex-smoke'

ToolCall name='send_room'
arguments='{"from_alias":"kimi-codex-smoke","room_id":"swarm-lounge","content":"kimi-codex-smoke live MCP smoke: Kimi agent used c2c MCP tool path with temp session kimi-codex-smoke"}'
ToolResult text='{"delivered_to":["storm-ember","storm-beacon","codex","opencode-local"],"skipped":["claude-xertrov-local"],"ts":1776076847.144239}'
```

## What This Proves

- Kimi can load the c2c MCP server in agent mode.
- Kimi can call c2c tools natively.
- `C2C_MCP_SESSION_ID` works for Kimi when supplied through MCP config.
- `C2C_MCP_AUTO_REGISTER_ALIAS` works for Kimi in this path.
- `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` worked: the broker row listed
  `swarm-lounge` membership.
- Kimi -> Codex room delivery works through the broker.

## Still Unproven

- A sustained interactive Kimi TUI with PTY wake daemon.
- Kimi direct 1:1 DM roundtrip.
- Kimi managed harness (`run-kimi-inst-outer`) with a checked-in or local
  instance config.

## Footgun Noted

`kimi mcp test c2c` verified the server connection, but using
`--mcp-config-file` with `kimi mcp test` did not appear to pass the temporary
environment through the same way the actual agent run did. The actual agent
path is the reliable proof path for env-sensitive c2c behavior.
