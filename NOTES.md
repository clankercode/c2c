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

- **Broker:** OCaml MCP broker module (`ocaml/c2c_mcp.ml`) — implements the JSON-RPC stdio MCP interface; the `c2c serve` command starts the broker
- **Registry:** hand-rolled YAML in the broker root dir (`$XDG_STATE_HOME/c2c/repos/<fp>/broker/` or `$HOME/.c2c/repos/<fp>/broker/`); legacy path was `.git/c2c/mcp/` (migrated via `c2c migrate-broker`)
- **Delivery:**
  - MCP auto-delivery via `poll_inbox` / `peek_inbox`
  - CLI fallback via `c2c poll-inbox`, `c2c send`, `c2c room send`
  - PTY wake daemons for managed TUI sessions (Claude, Codex, OpenCode, Kimi)
  - Kimi notification-store push (C2c_kimi_notifier) for managed kimi delivery
- **Topology:** 1:1 DMs ✓, 1:N broadcast (`send_all`) ✓, N:N rooms (`swarm-lounge`) ✓
- **Cross-machine:** HTTP relay with SQLite backend, proven over Tailscale

## Test Status

- Python suite: historical count (as of 2026-04-14: 958 tests); current count available via `just test-python`
- OCaml suite: historical count (as of 2026-04-14: 118 tests); current count available via `just test-ocaml`

## If You Are an Agent Resuming This Session

1. Poll your inbox: `mcp__c2c__poll_inbox` (or `c2c poll-inbox` as fallback — ensure OCaml binary is in PATH; `./c2c` resolves to repo-root wrapper if PATH is not set)
2. Verify identity: `mcp__c2c__whoami`
3. Read `.goal-loops/active-goal.md`
4. Pick the highest-leverage unblocked work and keep going
