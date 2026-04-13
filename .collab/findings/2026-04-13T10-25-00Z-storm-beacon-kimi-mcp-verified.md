# Kimi Code MCP Broker Connection Verified

- **Time:** 2026-04-13T10:25:00Z
- **Reporter:** storm-beacon
- **Severity:** positive — key milestone

## What Was Verified

Running `kimi mcp test c2c` from the c2c-msg repo after `c2c setup kimi --force`:

```
Testing connection to 'c2c'...
✓ Connected to 'c2c'
  Available tools: 16
  Tools:
    - register, list, send, whoami, poll_inbox, peek_inbox, sweep,
      send_all, join_room, leave_room, send_room, list_rooms, my_rooms,
      room_history, history, tail_log
```

All 16 MCP tools are visible. The c2c OCaml broker starts correctly when Kimi
initiates the stdio MCP connection.

## Config State

`~/.kimi/mcp.json` now includes:
- `C2C_MCP_BROKER_ROOT`: `/home/xertrov/src/c2c-msg/.git/c2c/mcp`
- `C2C_MCP_AUTO_REGISTER_ALIAS`: `kimi-xertrov-x-game`

Kimi reads its MCP config from `~/.kimi/mcp.json` by default (confirmed via
`kimi mcp list`).

## What Is Still Unproven

- **Auto-registration**: `C2C_MCP_AUTO_REGISTER_ALIAS` is set, but we need a
  live interactive Kimi TUI session to confirm that the broker auto-registers
  the alias `kimi-xertrov-x-game` at startup.
- **Send/receive roundtrip**: Need to verify that calling `mcp__c2c__register`
  and `mcp__c2c__send` from within a live Kimi TUI session works end-to-end.
- **PTY wake delivery**: `c2c_kimi_wake_daemon.py` is written but not tested
  with real Kimi PTY coordinates.

## Crush Status

`~/.config/crush/crush.json` has the c2c MCP entry with auto-alias
`crush-xertrov-x-game`. However, `crush run` requires a provider configured
interactively first. Status: config ready, live test pending.

## North-Star Impact

This confirms that Kimi Code's MCP infrastructure is compatible with the c2c
broker. The full send/receive path should work once a Kimi TUI session is
tested interactively.
