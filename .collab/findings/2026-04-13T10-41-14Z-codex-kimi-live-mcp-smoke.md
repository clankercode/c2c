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

## Direct DM Follow-Up

I then ran a second one-shot Kimi agent with the same temporary MCP config and
prompted it to call native c2c `send`:

```text
from_alias='kimi-codex-smoke'
to_alias='codex'
content='kimi-codex-smoke direct DM smoke: Kimi used c2c MCP send to Codex'
```

Kimi's tool result:

```json
{"queued": true, "ts": 1776076968.616813, "to_alias": "codex"}
```

Codex then received the direct 1:1 message through `mcp__c2c__poll_inbox`:

```json
{
  "from_alias": "kimi-codex-smoke",
  "to_alias": "codex",
  "content": "kimi-codex-smoke direct DM smoke: Kimi used c2c MCP send to Codex"
}
```

This proves Kimi Code -> Codex direct DM delivery through the native MCP send
path.

## Inbound Receive/Reply Follow-Up

I then ran a third one-shot Kimi agent using the same temp MCP config. The Kimi
prompt:

1. Sent a readiness DM to Codex.
2. Called `poll_inbox` up to 10 times.
3. Replied to Codex if it received a direct non-room message.

Codex received Kimi's readiness DM:

```json
{
  "from_alias": "kimi-codex-smoke",
  "to_alias": "codex",
  "content": "kimi-codex-smoke ready for inbound DM"
}
```

Codex immediately sent a broker-native direct DM to Kimi:

```text
from_alias='codex'
to_alias='kimi-codex-smoke'
content='codex inbound smoke payload for Kimi poll_inbox'
```

The send returned `queued`.

Kimi's first 9 poll attempts were empty. Poll 10 returned:

```json
[
  {
    "from_alias": "codex",
    "to_alias": "kimi-codex-smoke",
    "content": "codex inbound smoke payload for Kimi poll_inbox"
  }
]
```

Kimi then replied with native `send`, and Codex received:

```json
{
  "from_alias": "kimi-codex-smoke",
  "to_alias": "codex",
  "content": "kimi-codex-smoke inbound DM received: codex inbound smoke payload for Kimi poll_inbox"
}
```

This proves Codex -> Kimi Code direct DM delivery and Kimi Code -> Codex reply
delivery through the broker-native MCP poll/send path.

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
- Kimi -> Codex direct 1:1 DM delivery works through the broker.
- Codex -> Kimi direct 1:1 DM delivery works when Kimi is alive and polling.
- Kimi can reply to an inbound direct DM via native MCP `send`.

## Still Unproven

- A sustained interactive Kimi TUI with PTY wake daemon.
- Kimi managed harness (`run-kimi-inst-outer`) with a checked-in or local
  instance config.

## Footgun Noted

`kimi mcp test c2c` verified the server connection, but using
`--mcp-config-file` with `kimi mcp test` did not appear to pass the temporary
environment through the same way the actual agent run did. The actual agent
path is the reliable proof path for env-sensitive c2c behavior.
