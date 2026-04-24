# Ephemeral Agent Primitive — SPEC

**Status**: APPROVED (coordinator1, 2026-04-24)
**Authors**: coordinator1 (design), jungle-coder (implementation)
**Related**: #143

## Problem

We have `c2c start <client>` (persistent managed peers) and subagents (throwaway in-conversation helpers). Neither serves the "short-lived, purpose-built agent that participates in c2c for one dialogue then cleanly shuts down" use case. The canonical example is `c2c agent refine` — a role-designer ephemeral that talks to the caller via c2c DMs, iterates on a role file, and exits when done.

## Design Decisions

### D1. Ephemeral = mode + reply-to + no-autojoin-rooms

Three properties define an ephemeral:
1. **Mode** — how it runs (pane / background / headless)
2. **reply-to** — where it sends completion results
3. **no-autojoin-rooms** — comes up quiet, no room noise

### D2. Entry point: `c2c agent run <role>`

Command: `c2c agent run <role-name> [--prompt "..."] [--name <name>] [--timeout N] [--reply-to <alias>] [--pane | --background | --headless] [--auto-join <rooms>]`

- User specifies the role file, not a bot name
- Name auto-generated as `eph-<role>-<word>-<word>` (`eph-` prefix makes it obvious in `c2c list`)
- `--name` override allowed (but rare)
- `--timeout` default: 1800s (30min); 0 disables
- `--reply-to` default: calling session's alias (resolved from `C2C_MCP_AUTO_REGISTER_ALIAS`)
- `--pane` / `--background` / `--headless` select the terminal harness (default: `--pane`)

### D3. Mode: Pane | Background | Headless

| Mode | Harness | Primary Use |
|------|---------|-------------|
| `--pane` | tmux new-window | human-observable one-shot (refine) |
| `--background` | detached daemon | fire-and-forget (review-bot fanout) |
| `--headless` | headless client | scripted codex-headless |

**Pane mode** (existing implementation at c2c.ml:7700-7800):
- Requires TMUX env var
- Writes kickoff to `~/.local/share/c2c/kickoff/<name>.md`
- tmux new-window running: `c2c start <client> -n <name> --kickoff-prompt-file <path> [--reply-to <alias>]`
- Process runs **directly in pane** — pane dies with child, no `kill-window`
- Watchdog fork (existing) handles idle timeout

**Background mode** (new):
- No tmux involvement
- `c2c start <client> -n <name> --kickoff-prompt-file <path> --reply-to <alias> &`
- Detached via double-fork or `nohup`
- Watchdog same as pane mode

**Headless mode** (new):
- Passes `--headless` through to `c2c start`
- Reuses existing headless plumbing (codex-headless etc.)
- Same watchdog applies

### D4. `--reply-to <alias>`: reply-channel primitive

- Passed as `--reply-to <alias>` to `c2c agent run`
- `c2c start` passes through as `C2C_MCP_REPLY_TO=<alias>` **new** env var to child process
- Child's kickoff template includes: *"When done, send your result to `C2C_MCP_REPLY_TO` via the `send` tool"*
- Works across all three modes

**Rationale**: threading `--reply-to` through at primitive-creation time beats retrofitting later. The kickoff template auto-references it so the ephemeral knows where to DM completion.

### D5. No autojoin rooms by default

- Ephemeral launch: do NOT set `C2C_MCP_AUTO_JOIN_ROOMS` unless explicitly passed
- Ephemeral comes up quiet — no room noise unless caller opts in via `--auto-join <rooms>`
- Contrast: persistent managed agents autojoin role-driven rooms

**Rationale**: review-bots and one-shot ephemerals should not flood rooms. The caller opts in if needed.

### D6. Idle timeout watchdog

- Fork-detached watchdog process (existing at c2c.ml:7706-7750)
- Polls inbox + archive mtime every `min(30s, timeout/4)` seconds
- Boot grace: 120s (pane) / 60s (background)
- If no activity for `timeout` seconds: SIGTERM child, exit 0
- Exits immediately when child exits

### D7. Self-termination

- Ephemeral calls `stop_self` MCP tool when done (contract in kickoff template)
- `stop_self` is aliased to `c2c stop <session>` targeting `C2C_MCP_SESSION_ID`
- No new tool needed — existing infrastructure

### D8. `c2c agent refine` composition

`c2c agent refine <role-name>` becomes a thin wrapper:
```bash
c2c agent run role-designer \
  --prompt "refine role <name> at <path>" \
  --name "eph-refine-<name>-<word>-<word>" \
  --reply-to <caller-alias>
```

## Implementation

### Files to modify

1. **`ocaml/cli/c2c.ml`**:
   - Add `--reply-to` flag to `agent_run_term` and `agent_refine_term`
   - Add `--background` and `--headless` mode flags to `agent_run_term`
   - Suppress `C2C_MCP_AUTO_JOIN_ROOMS` in `run_ephemeral_agent` for ephemeral modes
   - Pass `C2C_MCP_REPLY_TO` through to `c2c start`
   - Add background/headless dispatch in `run_ephemeral_agent`

2. **`ocaml/c2c_start.ml`**:
   - Add `--reply-to` CLI flag to `start_cmd`
   - Add `C2C_MCP_REPLY_TO` env var handling
   - Background mode: add detach-daemon path in `run_outer_loop`
   - Headless mode: detect `--headless` flag and route appropriately

3. **`ocaml/c2c_start.mli`**: Add signature for new exported functions

### Kickoff template update

The kickoff template (in `run_ephemeral_agent`) should include:
```
When your task is complete:
1. Confirm completion with the caller by sending a DM to C2C_MCP_REPLY_TO.
2. Call `stop_self` to terminate cleanly.
```

### Env var summary for ephemeral child

| Env Var | Value |
|---------|-------|
| `C2C_MCP_SESSION_ID` | instance name (set by c2c start) |
| `C2C_MCP_REPLY_TO` | caller alias (new env var, from --reply-to) |
| `C2C_MCP_AUTO_JOIN_ROOMS` | unset by default (unless --auto-join) |
| `C2C_MCP_CLIENT_TYPE` | client type (set by c2c start) |

## Test Plan

1. **Unit**: flag parsing, env var threading, kickoff template composition, name allocation
2. **Dogfood**: `c2c agent refine <new-role>` with coordinator1 observing — ephemeral spins up, appears in `c2c list`, can DM caller, closes cleanly on `stop_self`, idle-timeout fires correctly when unattended
3. **Integration**: end-to-end with minimal role file in each mode (pane, background, headless)

## Anti-goals

- No scheduling / cron (future sidequest)
- No multi-instance fleets
- No dedicated broker namespace (ephemerals use normal aliases)
- No `tmux kill-window` (pane closes naturally with child)