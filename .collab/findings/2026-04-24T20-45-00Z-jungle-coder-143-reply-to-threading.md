# #143 implementation tracing — C2C_MCP_REPLY_TO threading

**Date**: 2026-04-24T20:45:00Z
**Status**: research complete, implementation pending spec approval

## Threading Path

```
agent_run_term (c2c.ml)
  └─ run_ephemeral_agent
       ├─ compose kickoff (includes C2C_MCP_REPLY_TO reference)
       └─ c2c_start ~name ~client ... (mode dispatch)
            └─ cmd_start ~(reply_to : string option)
                 └─ run_outer_loop ~reply_to
                      └─ build_env ~(reply_to_override : string option)
                           └─ adds "C2C_MCP_REPLY_TO", reply_to to env additions
```

## Key Locations

- `build_env` (c2c_start.ml:929) — add `?(reply_to_override : string option = None)`, add to additions list
- `run_outer_loop` (c2c_start.ml:1784) — add `?reply_to` param, pass to `build_env`
- `cmd_start` (c2c_start.ml:2443) — add `?reply_to` param, pass to `run_outer_loop`
- `c2c.ml run_ephemeral_agent` (c2c.ml:7583) — parse `--reply-to` flag, pass to `c2c_start`

## Env Var Format

```
C2C_MCP_REPLY_TO=<alias>
```

## Background Mode Implementation

Background mode needs a detach mechanism. Key question: does `run_outer_loop` currently support a detach mode, or does background need a separate path?

Current `run_outer_loop`:
- Sets up PTY/tty
- Runs the outer loop synchronously
- Returns exit code

For background mode, we'd need to fork and detach before the outer loop, or have a separate "run detached" path. The pane mode already has a watchdog fork — same pattern can work.

## Headless Mode

`c2c start codex-headless` already has headless plumbing. The `--headless` flag would route to the codex-headless client type. No new infrastructure needed — just a mode flag that sets `client = "codex-headless"` or passes `--headless` through.