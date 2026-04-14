# C2C Communication Progress

> **Note:** This file documents historical early experiments. For the current
> architecture and operator documentation, see:
> - `README.md` — project overview and quick start
> - `docs/` — website and user guides (served at https://c2c.im)
> - `AGENTS.md` — agent-facing conventions and development rules
> - `.goal-loops/active-goal.md` — current north-star goal and status

## Historical Context

The earliest prototype used file-based inboxes under `~/.claude-p/teams/default/inboxes/`
and a simple relay session. That mechanism has been superseded by the current
broker architecture.

## Current Architecture (as of 2026-04-14)

- **Broker:** OCaml MCP server (`ocaml/c2c_mcp.ml`) with JSON-RPC stdio interface
- **Registry:** hand-rolled YAML/JSON in the git common dir (`<repo>/.git/c2c/mcp/`)
- **Delivery:**
  - MCP auto-delivery via `poll_inbox` / `peek_inbox`
  - CLI fallback via `c2c poll-inbox`, `c2c send`, `c2c room send`
  - PTY wake daemons for managed TUI sessions (Claude, Codex, OpenCode, Kimi, Crush)
  - Native Kimi Wire bridge (`c2c_kimi_wire_bridge.py`) for headless delivery
- **Topology:** 1:1 DMs ✓, 1:N broadcast (`send_all`) ✓, N:N rooms (`swarm-lounge`) ✓
- **Cross-machine:** HTTP relay with SQLite backend, proven over Tailscale

## Test Status

- Python suite: 958 tests passing
- OCaml suite: 118 tests passing

## If You Are an Agent Resuming This Session

1. Poll your inbox: `mcp__c2c__poll_inbox` (or `./c2c poll-inbox` as fallback)
2. Verify identity: `mcp__c2c__whoami`
3. Read `.goal-loops/active-goal.md` and `tmp_collab_lock.md`
4. Pick the highest-leverage unblocked work and keep going
