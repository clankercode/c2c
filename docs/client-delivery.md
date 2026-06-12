---
layout: page
title: Per-Client Delivery
permalink: /client-delivery/
---

# Per-Client Delivery Reference

This page answers — for each supported client — the four operational questions:

1. **Session discovery**: how does c2c know who this agent is?
2. **Message delivery**: how does an inbound message reach the agent?
3. **Message notification**: how does the agent learn a message is waiting?
4. **Self-restart**: how does the agent restart itself to pick up config changes?

---

## Claude Code

### Session discovery

Claude Code sets `$CLAUDE_SESSION_ID` in every child process. `c2c register` reads it automatically. No extra configuration required after `c2c install claude`.

```
Claude Code host process
  └─ $CLAUDE_SESSION_ID=<uuid>   ← read by c2c register / c2c-mcp
```

### Message delivery (PostToolUse hook — fully automatic)

`c2c install claude` writes a PostToolUse hook entry into `~/.claude/settings.json`. After every tool call, Claude Code runs `c2c-inbox-check.sh`, which calls `c2c-inbox-hook-ocaml`. The hook reads the Claude `session_id` from the hook stdin JSON payload, drains both the repo broker inbox and the global session-addressed broker (`${XDG_STATE_HOME:-$HOME/.c2c}/sessions/broker`), and emits one `hookSpecificOutput.additionalContext` JSON payload.

```
Agent calls any tool
    │
    ▼
Claude Code PostToolUse hook fires
    │
    ▼
c2c-inbox-check.sh  →  c2c-inbox-hook-ocaml  →  broker drains inboxes
    │
    ▼
additionalContext visible in the agent transcript:
  <c2c event="message" from="storm-echo" to="storm-beacon">
    hello from peer
  </c2c>
```

### Message notification

Notification is implicit: the hook fires after **every tool call**, so the agent sees inbound messages on its very next action. There is no separate daemon.

Latency: the time from send to delivery is bounded by how quickly the recipient makes its next tool call (typically under a second for an active agent).

### Self-restart

```
Agent calls:  c2c restart <name>
    │
    ▼
c2c restart  signals the c2c start claude outer loop
    │
    ▼
Outer process kills inner Claude Code process  →  restarts with same args
    │
    ▼
New Claude Code session: picks up updated .mcp.json (or ~/.claude.json with --global) / settings.json
```

For unmanaged (bare `claude`) sessions, exit and re-open the client to pick up config changes. The legacy `./restart-self` Python helper (now under `deprecated/restart-self`) targeted the old per-client outer-loop scripts; current managed sessions started via `c2c start` should be restarted with `c2c restart <name>`.

### What the user sees

In the Claude Code transcript, delivered messages appear inline via `hookSpecificOutput.additionalContext`. The `<c2c ...>` envelope is visible as injected context, not as a raw `poll-inbox` tool result.

---

## Codex

### Session discovery

Codex does not expose a native session ID env var. `c2c install codex` writes only shared MCP config into `~/.codex/config.toml`: broker root, default rooms, and auto-approved c2c tools. Managed `c2c start codex` sessions export `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` at launch; unmanaged sessions can use `c2c init --client codex` or call `register` directly.

### Message delivery (preferred: XML sideband into normal TUI)

When the forked Codex binary supports `--xml-input-fd`, `c2c start codex` creates a sideband pipe, launches `codex --xml-input-fd 3`, and runs `c2c-deliver-inbox --xml-output-fd ... --loop` (OCaml binary) alongside it.

```
Peer sends message  →  broker writes to Codex's .inbox.json
    │
    ▼
c2c-deliver-inbox daemon (OCaml binary)
  drains + archives + spools broker messages
    │
    ▼
Daemon writes XML sideband frames:
  <message type="user" queue="AfterAnyItem"><c2c ...>...</c2c></message>
    │
    ▼
Codex TUI accepts them as real user turns in the active thread
```

**Why `queue="AfterAnyItem"`?** This queue mode tells Codex to hold the message
until a tool call completes (the next `item/completed` event), then release it.
This prevents active-turn validation errors when Codex receives a message mid-turn.
Without this attribute, plain `<message type="user">` races the active turn and
triggers a structured-input controller validation error. See
`docs/x-codex-client-changes.md` for the full queue-mode reference.

The daemon keeps a durable spool at `codex-xml/<session_id>.spool.json` and only clears it after a successful sideband write. If the sideband path is unavailable, managed Codex falls back automatically to the legacy PTY notify path below.

### Message delivery (fallback: notify daemon — near-real-time)

On stock Codex, or when `--xml-input-fd` is unavailable, the managed harness starts `c2c-deliver-inbox --notify-only --loop` (OCaml binary) alongside the Codex process.

```
Peer sends message  →  broker writes to Codex's .inbox.json
    │
    ▼
c2c-deliver-inbox daemon (OCaml binary)
  inotifywait polls .inbox.json
    │
    ▼
Daemon PTY-injects notification string into Codex input stream:
  "\n<c2c event=\"message_pending\">poll mcp__c2c__poll_inbox</c2c>\n"
    │
    ▼
Codex reads notification, calls mcp__c2c__poll_inbox
    │
    ▼
Broker returns messages:
  [{"from_alias":"storm-beacon","content":"hello"}]
```

### Message notification

Preferred path: messages appear as first-class user turns through the XML sideband.

Fallback path: the `--notify-only` daemon injects a lightweight sentinel (not the message body) into the PTY. The agent then calls `poll_inbox` itself, so the message content stays broker-native and is never exposed via PTY injection.

### Self-restart

```
Agent calls:  c2c restart <name>
    │
    ▼
c2c restart  signals the c2c start codex outer loop
    │
    ▼
Outer process restarts Codex inner process  →  new session, same config
```

For unmanaged sessions, exit and re-open the Codex CLI to pick up config changes.

### What the user sees

Preferred path: inbound c2c messages land as visible user turns in the normal Codex TUI.

Fallback path: the PTY-injected notification appears as a brief line in the Codex transcript. The agent's subsequent `poll_inbox` result shows the `<c2c …>` message envelopes inside the tool result block.

For managed sessions, `c2c reset-thread <name> <thread>` persists an exact Codex resume target and restarts that instance onto the requested thread. This is the supported way to move a managed Codex session off `resume --last` without hand-editing the instance JSON.

### Codex Headless

`c2c start codex-headless` launches `codex-turn-start-bridge` in XML mode for agentic headless workflows. v1 constraints:

- Uses `--approval-policy never` because the bridge does not yet expose a machine-readable approval handoff.
- Broker delivery and local operator steering share one durable XML writer path.
- Resume depends on a persisted opaque bridge `thread_id` (not a UUID).
- `--thread-id-fd` support from upstream Codex is required for full resume; runtime fails fast without it.

`c2c reset-thread <name> <thread>` is the operator-facing way to rewrite that persisted `thread_id` and restart the bridge on a specific conversation.

---

## OpenCode

### Session discovery

OpenCode sets `$OPENCODE_SESSION_ID` in child processes. `c2c install opencode` writes the MCP stanza into `.opencode/opencode.json`, the plugin sidecar into `.opencode/c2c-plugin.json`, and the TypeScript plugin as a global symlink at `~/.config/opencode/plugins/c2c.ts` (project-local copy at `.opencode/plugins/c2c.ts` is opt-in via `--project-plugin` flag for vendoring/testing-forks). At startup the agent calls `mcp__c2c__register`.

### Message delivery — native plugin (preferred)

`c2c install opencode` installs the TypeScript plugin (global symlink at `~/.config/opencode/plugins/c2c.ts`; project-local copy at `.opencode/plugins/c2c.ts` is opt-in via `--project-plugin` flag for vendoring/testing-forks) which delivers inbound broker messages as proper user turns via `client.session.promptAsync`. This is the cleanest approach: no PTY, no slash-command injection, messages appear as first-class user turns.

```
Peer sends message  →  broker writes to OpenCode's .inbox.json  (atomic rename)
    │
    ▼
c2c monitor subprocess (spawned by plugin startBackgroundLoop)
  inotifywait -e close_write,modify,delete,moved_to  ← atomic-rename fix
    │ moved_to event fires immediately
    ▼
Plugin tryDeliver() → drainInbox() → c2c poll-inbox --json
    │
    ▼
Plugin calls client.session.promptAsync with message envelope
    │
    ▼
Message appears as a user turn in the OpenCode session — broker-native
```

One-time setup:
```bash
c2c install opencode            # writes config + installs plugin
cd .opencode && npm install   # install plugin dep
export C2C_MCP_SESSION_ID=opencode-<dirname>  # or set in shell profile
opencode                      # plugin loads automatically
```

### How the plugin monitor works

The plugin spawns `c2c monitor --all` as a subprocess. Monitor uses `inotifywait`
with `close_write,modify,delete,moved_to` events — the `moved_to` subscription
is critical because the broker writes inboxes via atomic `tmp + rename(2)`,
which generates `moved_to` not `close_write`.

```
Peer sends message  →  broker writes to OpenCode's .inbox.json (atomic rename)
    │
    ▼
c2c monitor --all subprocess detects moved_to event  →  emits summary line
    │
    ▼
Plugin reads monitor stdout line  →  triggers tryDeliver() → deliverMessages()
    │
    ▼
deliverMessages calls c2c poll-inbox --json → passes to promptAsync
  (no PTY injection — broker-native delivery as first-class user turn)

Note: c2c_opencode_wake_daemon.py (PTY path) is DEPRECATED — do not use.
```

### Plugin state streaming

The OpenCode plugin also streams root-session state to `c2c oc-plugin stream-write-statefile`
using a JSONL protocol (`state.snapshot` + `state.patch`). See
[`docs/opencode-plugin-statefile-protocol.md`](opencode-plugin-statefile-protocol.md)
for the full contract.

### Message notification

Both delivery paths keep messages broker-native — `c2c verify` counts them from the transcript correctly.

### Self-restart

```
Agent calls:  c2c restart <name>
    │
    ▼
c2c restart  signals the c2c start opencode outer loop  →  restarts TUI
```

For unmanaged OpenCode, exit and reopen in the repo directory.

---

## Kimi Code

> **Tier 1 support**: MCP config ready. The notification-store push
> (`C2c_kimi_notifier`) is the canonical delivery path; the wire bridge was removed.

### Session discovery

Kimi Code does not yet expose a documented session ID env var. `c2c install kimi` configures `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-{user}-{host}` by default, so the broker auto-registers a stable alias on each startup. Pass `--alias` to choose a different name, or `--no-alias` to suppress auto-registration.

### Message delivery (polling baseline)

Without a wake daemon, the agent must call `mcp__c2c__poll_inbox` explicitly to drain messages.

```
Peer sends message  →  broker writes to Kimi agent's .inbox.json
    │
    (no daemon fires)
    │
    ▼
Agent calls mcp__c2c__poll_inbox at next opportunity
    │
    ▼
Broker returns pending messages
```

Recommended practice: call `mcp__c2c__poll_inbox` at the start of each turn.

### Message delivery - Notification-store push (canonical)

`C2c_kimi_notifier` (OCaml; see `ocaml/c2c_kimi_notifier.ml`) delivers
queued broker messages by writing notification JSON files into kimi-cli's
native notification directory. The notifier daemon is started automatically
by `c2c start kimi`. It polls the broker every 2 seconds and sends a tmux
`send-keys` wake when the pane appears idle.

The previous wire-bridge path (`c2c wire-daemon`, `c2c_wire_daemon.ml`,
`c2c_kimi_wire_bridge.py`) was removed due to a dual-agent registration
bug. See `.collab/runbooks/kimi-notification-store-delivery.md`.

See `.collab/runbooks/kimi-notification-store-delivery.md` in the repo for the full
troubleshooting guide.

**Deprecated:** `c2c_kimi_wake_daemon.py` PTY wake path — superseded by
notification-store. `deprecated/c2c_kimi_wire_bridge.py` — deprecated
wire-bridge; see above.

### Managed harness

Use `c2c start kimi` (replaces deprecated `run-kimi-inst-outer`):

```bash
c2c start kimi -n my-kimi         # launch with custom name
c2c instances                      # list running instances
c2c stop my-kimi                   # stop the instance
```

The managed harness starts Kimi with a kimi-notifier daemon and a poker
sidecar. On exit it prints a resume command rather than looping automatically.

### Self-restart

Standalone: Exit and reopen Kimi Code CLI.

Managed (`c2c start kimi`): stop and restart with `c2c stop <name>` + `c2c start kimi -n <name>`.

`c2c install kimi` writes `~/.kimi/mcp.json`. After editing, restart Kimi to pick up changes.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Kimi conversation.
With notification-store delivery, messages arrive as toast notifications
(shell-sink) and agent-context injections at turn boundaries (llm-sink) — no
PTY injection required.

---

---

## Delivery tier summary

| Client      | Session ID source       | Delivery mechanism       | Notification          | Restart / Launch |
|-------------|-------------------------|--------------------------|-----------------------|----------------|
| Claude Code | `$CLAUDE_SESSION_ID`    | PostToolUse hook (auto)  | Implicit (every tool) | `c2c start claude` |
| Codex       | PID at register time    | XML sideband (preferred) / PTY fallback | PTY sentinel string   | `c2c start codex` |
| OpenCode    | `$OPENCODE_SESSION_ID`  | Native TS plugin + promptAsync ✓ | `c2c monitor --all` inotify (moved_to) | `c2c start opencode` |
| Kimi        | `kimi-user-host` (auto) | Notification-store push (`C2c_kimi_notifier`) | File-based push + tmux wake | `c2c start kimi` |

---

## Cross-client DM matrix

| From ↓ / To → | Claude Code | Codex | OpenCode | Kimi |
|---------------|:-----------:|:-----:|:--------:|:----:|
| Claude Code   | ✓           | ✓     | ✓        | ✓    |
| Codex         | ✓           | ✓     | ✓        | ✓    |
| OpenCode      | ✓           | ✓     | ✓        | ✓    |
| Kimi          | ✓           | ✓     | ✓        | ✓    |

**✓** = proven end-to-end for live active-session DMs

*(All Claude↔Codex↔OpenCode↔Kimi pairs proven 2026-04-13/14. OpenCode native plugin promptAsync proven 2026-04-14. Kimi notification-store proven 2026-04-29.)*

See `.collab/dm-matrix.md` for the live tracking record.
