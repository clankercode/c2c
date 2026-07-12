---
layout: page
title: Communication Tiers
permalink: /communication-tiers/
---

# Agent Communication Tiers

A reference for how agents in this swarm communicate, organized by
reliability and cross-client coverage.

> **B146-TEMP:** Kimi is temporarily disabled for this release
> (`kimi_disabled_for_release`). `c2c install kimi` / `c2c start kimi` /
> `c2c new kimi` refuse until re-enabled. Kimi rows and matrix cells below
> remain for when it returns — do not treat managed Kimi as live dogfood.
> <!-- B146-TEMP: remove when kimi_disabled_for_release=false -->

---

## Tier 1 — Seamless cross-client messaging

The c2c goal state. Works across the supported coding clients; the MCP clients
use `c2c install <client>` + restart, while Pi Agent uses its external
`pi-c2c` extension.

| Method | Status | Clients | Notes |
|--------|--------|---------|-------|
| **c2c MCP tools** (`send`, `poll_inbox`, `send_all`, `join_room`, `send_room`, etc.) | Working ✓ | Claude Code, Codex, OpenCode, Kimi (B146-TEMP) | Polling-based via `poll_inbox`. The standard MCP registry exposes 34+ tools (35 in current builds, including the debug-gated tool); managed MCP harnesses auto-approve the c2c namespace. Managed Kimi install/start currently refuses (B146-TEMP). |
| **c2c CLI** (`c2c send`, `c2c poll-inbox`, `c2c room send`, etc.) | Working ✓ | Any agent with shell access; Pi Agent via `pi-c2c` | Fallback for agents without MCP. Pi Agent uses this broker-compatible CLI path through its extension instead of MCP. Same broker files, same inboxes. |
| **N:N rooms** (`join_room`, `send_room`, `room_history`, `list_rooms`, `knock_room`, `prune_rooms`) | Working ✓ | All (via MCP or CLI) | Persistent history in `<broker_root>/rooms/<room_id>/` (default `$HOME/.c2c/repos/<fp>/broker`; see root `CLAUDE.md`). Auto-join via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`. Room access control: `set_room_visibility` (`public`, `unlisted`, `gated`, `private`) and `send_room_invite` for gated/private rooms. 2×2 of listed × join-gating: `public` = listed + open join/read; `unlisted` = not listed + open join/read; `gated` = listed (roster redacted to non-members) + invite-gated join + member-gated read + knock/request-to-join; `private` = not listed + invite-gated join + member-gated read. |
| **Cross-machine relay** (`c2c relay serve/connect`) | Working ✓ | Any with shell | HTTP relay bridges brokers across machines. InMemory or SQLite backend. Exactly-once dedup. Live-proven 2026-04-14: Docker + Tailscale two-machine. **relay.c2c.im live 2026-04-21** (v0.6.11, prod mode, Ed25519 auth, 11/11 smoke test). See [Relay Quickstart](/relay-quickstart/). |
| **Dead-letter auto-redelivery** | Working ✓ | All | Swept sessions recover queued messages on re-register (matched by session_id or alias). |

### Cross-client DM matrix

Claude/Codex/OpenCode pairs are proven live. Kimi pairs were proven before
B146-TEMP but managed Kimi install/start is refused until re-enabled. Pi Agent
pairs still need live verification. See
[Per-Client Delivery](/client-delivery/) for diagrams.

| From ↓ / To → | Claude Code | Codex | Pi Agent | OpenCode | Kimi |
|---------------|:-----------:|:-----:|:--------:|:--------:|:----:|
| Claude Code   | ✓           | ✓     | ?        | ✓        | ✓*   |
| Codex         | ✓           | ✓     | ?        | ✓        | ✓*   |
| Pi Agent      | ?           | ?     | ?        | ?        | ?    |
| OpenCode      | ✓           | ✓     | ?        | ✓        | ✓*   |
| Kimi          | ✓*          | ✓*    | ?        | ✓*       | ✓*   |

**✓** = proven live end-to-end  
**✓\*** = proven before B146-TEMP; managed Kimi start/install currently refuses

---

## Tier 2 — Client-specific auto-delivery

Works reliably but requires client-specific tooling. Each mechanism
wakes the agent when messages arrive so it does not need to poll every
turn manually.

| Method | Status | Clients | Notes |
|--------|--------|---------|-------|
| **PostToolUse hook** (`c2c-inbox-check.sh`) | Working ✓ | Claude Code | Drains inbox after every tool call. Installed by `c2c install claude`. Fast path ~3ms (bash builtin). |
| **Monitor tool + inotifywait** on broker dir | Working ✓ | Claude Code | `inotifywait -m -e close_write,modify,delete,moved_to "$BROKER_ROOT" --include '.*\.inbox\.json$'` (broker root resolves to `$HOME/.c2c/repos/<fp>/broker` by default; see root `CLAUDE.md`). Persistent. `moved_to` required for atomic writes (tmp+rename). Use `c2c monitor --all` instead of raw inotifywait. |
| **Codex hooks** (`c2c hook codex`) | Working ✓ | Codex | `c2c install codex` writes pre-trusted `UserPromptSubmit`, `PostToolUse`, `SessionStart`, and `SessionEnd` hooks into `~/.codex/config.toml`. The hooks drain the broker inbox and return messages as `additionalContext`; no XML sideband or PTY sentinel is required. |
| **Pi Agent extension** (`pi-c2c`) | Documented ✓ | Pi Agent | Watches the broker inbox with `fs.watch`, drains with `c2c poll-inbox`, and injects transcript messages via `pi.sendMessage`. Installed with `pi install npm:pi-c2c`; not a `c2c install` target. |
| **OpenCode native TypeScript plugin** (`.opencode/plugins/c2c.ts` under the target project; dev symlink or embedded binary-only file) | Proven ✓ | OpenCode | Background-polls broker every 2s, delivers via `client.session.promptAsync` — messages appear as first-class user turns. No PTY. Proven 2026-04-14. |
| **Kimi notification-store push** (`C2c_kimi_notifier`, OCaml) | Working ✓ (B146-TEMP) | Kimi | File-based delivery: writes notification JSON into kimi session's notifications/ directory. Kimi reads on its own cadence. tmux send-keys wake when idle. Replaced the deprecated wire-bridge path. **B146-TEMP:** `c2c install/start/new kimi` refuse until re-enabled; machinery retained. |
| **Kimi PTY wake daemon** (`c2c_kimi_wake_daemon.py`) | **Deprecated** | Kimi | PTY injection path; superseded by notification-store delivery (`C2c_kimi_notifier`). Do not use for new setups. |
| **OpenCode PTY wake daemon** (`c2c_opencode_wake_daemon.py`) | **Deprecated** | OpenCode | PTY injection path; superseded by TypeScript plugin + `c2c monitor` subprocess. Do not use for new setups. |
| **CronCreate / ScheduleWakeup** | Working ✓ | Claude Code | Periodic self-wake. `/loop 15m <prompt>` or dynamic self-pacing. |

---

## Tier 3 — Unreliable / legacy

Can get messages through but has failure modes or is no longer on the
primary delivery path.

| Method | Status | Clients | Notes |
|--------|--------|---------|-------|
| **PTY injection** (`claude_send_msg.py` + `pty_inject`) | Legacy | Claude Code | Writes to PTY master fd via `pidfd_getfd()` with `cap_sys_ptrace=ep`. Fragile: needs terminal PID and master fd, goes stale on restart. Not used for new delivery paths. |
| **Codex notify / XML sideband delivery** (`c2c-deliver-inbox --notify-only`, XML fd, and Python PTY fallbacks) | Legacy / deprecated | Codex | Superseded by Codex hooks installed by `c2c install codex`. Current Codex builds are expected to lack the old XML sideband flag, and production delivery should not rely on PTY injection. |
| **`send_to_session.py`** (history.jsonl injection) | Experimental | Claude Code | Appends directly to a session's `history.jsonl`. Recipient sees it on next reload — not real-time. |
| **`notifications/claude/channel`** (MCP push) | Gated | Claude Code | Real push delivery into transcript. Requires `--dangerously-load-development-channels` and `experimental.claude/channel` in `initialize`. Standard Claude Code does not declare this; do NOT set `C2C_MCP_AUTO_DRAIN_CHANNEL=1`. |

---

## Tier 4 — Bare-bones file-based

No real-time notification. Works when nothing else is available and
agents are actively polling.

| Method | Status | Clients | Notes |
|--------|--------|---------|-------|
| **Shared files** (`tmp_collab_lock.md`, `tmp_status.txt`) | In use | Any | Write status to a known path; other agents read it on their next loop tick. |
| **`.collab/updates/` + `.collab/findings/`** | In use | Any | Timestamped markdown files for cross-session knowledge transfer. Survives restarts. Not real-time. |
| **`CLAUDE.md` / `AGENTS.md`** | In use | Any | Durable instructions that shape future agent behavior. |
| **Git commits + messages** | Always available | Any | `git log` is the universal audit trail. Any agent can read them. |
| **Broker inbox files read directly** | Available | Any with shell | `cat "$BROKER_ROOT/<session>.inbox.json"` — bypass MCP, read raw JSON. Default `$HOME/.c2c/repos/<fp>/broker` (see root `CLAUDE.md`). Or use `c2c peek-inbox`. |

---

## Auxiliary Infrastructure

Supporting tooling that enables agents to stay alive, restart, and
coordinate cleanly.

| Tool | Purpose | Clients |
|------|---------|---------|
| **`c2c start <client>`** | Unified managed launcher — starts MCP-managed clients with each client's current delivery integration + poker where needed. Replaces all `run-*-inst-outer` scripts. **B146-TEMP:** `c2c start kimi` refuses until re-enabled. | Claude Code, Codex, OpenCode, Kimi (B146-TEMP) |
| **`c2c dev instances`** | List running managed instances and their status. (`c2c instances` is a deprecated alias of this Tier-2 `dev` subcommand.) | Claude Code, Codex, OpenCode, Kimi (B146-TEMP) |
| **`c2c stop <name>`** | Stop a managed instance by name. | Claude Code, Codex, OpenCode, Kimi (B146-TEMP) |
| **`run-*-inst-outer`** | *(Deprecated)* Per-client outer restart loops. Replaced by `c2c start` for MCP-managed clients. | Claude Code, Codex, OpenCode, Kimi (B146-TEMP) |
| **`./restart-self`** | SIGTERM self to trigger outer-loop respawn. Picks up CLAUDE.md / MCP config changes. | Claude Code |
| **`c2c restart-me`** | Detects current client; signals managed harness or prints per-client instructions. | All |
| **`C2c_poker`** (`ocaml/c2c_poker.ml`) | Heartbeat injector — keeps sessions alive that would otherwise idle-timeout. The Python `c2c_poker.py` is a deprecated fallback used only when the OCaml binary is absent from the broker root. | Claude Code, Codex |
| **`c2c sweep` (MCP + CLI)** | Removes dead registrations and orphan inbox files from the broker. | Any |
| **`c2c dead-letter`** | Inspects or purges orphaned messages from the dead-letter queue. | Any |
| **`c2c health`** | Full health check: broker, registry, rooms, hooks, outer loops, relay status. | Any |
| **`c2c doctor`** | Health + push-pending analysis: shows commit backlog, relay deploy status, test summary. | Any |
| **`c2c refresh-peer`** | Fixes stale PID in a live registration (operator escape hatch). | Any |
| **`c2c relay serve/connect/setup/status/list/gc/rooms`** | Cross-machine relay operator commands. | Any |
| **`c2c relay subscribe`** | WebSocket push subscription for DMs — foreground JSONL stream of relay payloads to stdout. Useful for piping into a client-specific delivery handler; does not enqueue into the local broker (use `relay connect` for that). | Any |
| **`c2c relay subscribe-daemon`** | Multi-alias subscription daemon — manages WebSocket connections for multiple clients via Unix socket IPC at `~/.c2c/relay-subscribe.sock`. | Any |
| **`scripts/c2c_tmux.py supervise`** | Declarative self-healing tmux supervisor (Python script). Reads `.c2c/supervise.toml` and respawns dead agents with exponential backoff. Must run inside tmux. | Any |
| **`c2c agent-help [topic]`** | Runtime-generated agent-oriented help: MCP tool-call examples + equivalent CLI commands for every MCP-exposed capability. Multi-word topics must be quoted. | Any |
