# Codex Native MCP Tool Namespace Was Stale Until Process Restart

- **Time:** 2026-04-13T06:53:45Z
- **Reporter:** codex
- **Severity:** medium

## Symptom

The live managed Codex session could not call native `mcp__c2c__*` tools even
though `~/.codex/config.toml` contained an enabled `mcp_servers.c2c` entry.
This forced Codex to use CLI/direct JSON-RPC fallbacks for C2C operations,
which looked like the C2C MCP path itself was broken.

## How It Was Discovered

The password-game direct-DM task required broker-native 1:1 messaging. Codex
could send through manual MCP JSON-RPC and CLI fallback paths, but no native
`mcp__c2c__send` / `mcp__c2c__poll_inbox` tool namespace existed in the current
Codex tool list.

Checks performed:

- `codex mcp list` showed `c2c` enabled with command
  `python3 /home/xertrov/src/c2c-msg/c2c_mcp.py`.
- Direct stdio calls through `python3 c2c_mcp.py` reported server version
  `0.6.1` and advertised the current tool list, including `poll_inbox`,
  `send`, `send_room`, `list_rooms`, and `room_history`.
- A fresh `codex exec` smoke test in this repo successfully called the native
  `c2c.poll_inbox` MCP tool and received `[]`.

## Root Cause

The running managed Codex process was started before the C2C MCP configuration
was available or before the latest server/tool namespace could be loaded. Codex
tool namespaces are fixed at process/session startup; updating config or
rebuilding the MCP server on disk does not add new `mcp__c2c__*` tools to an
already-running Codex process.

This was not an OCaml server staleness issue when launched through
`c2c_mcp.py`: the wrapper rebuilds and launches the current server, and the
fresh process saw `serverInfo.version = 0.6.1`.

## Fix Status

Confirmed recovery path: restart the managed Codex process with
`restart-codex-self` / `run-codex-inst-outer` so Codex reloads MCP config and
reconstructs its tool list. The restart marker should remind the resumed
session to first try native `mcp__c2c__poll_inbox`, then fall back to
`./c2c-poll-inbox --session-id codex-local --json` if host MCP startup still
fails.

## Follow-Ups

- Add a cheap launcher smoke check that can prove a freshly launched Codex
  instance sees `c2c.poll_inbox`.
- Consider documenting in Codex onboarding that MCP server config changes
  require a process restart; rebuilding the server is not enough.
- Keep CLI/direct JSON-RPC fallbacks available because they are still useful
  when a long-lived host process predates MCP configuration.
