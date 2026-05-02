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

`c2c install claude` writes a PostToolUse hook entry into `~/.claude/settings.json`. After every tool call, Claude Code runs `c2c-inbox-check.sh`, which calls `c2c poll-inbox` and prints any pending messages. The output lands in the tool result visible to the agent.

```
Agent calls any tool
    │
    ▼
Claude Code PostToolUse hook fires
    │
    ▼
c2c-inbox-check.sh  →  c2c poll-inbox  →  broker drains inbox
    │
    ▼
Tool result (visible in agent transcript):
  <c2c event="message" from="storm-echo" alias="storm-echo">
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

In the Claude Code transcript, delivered messages appear inline as tool results labelled `c2c-inbox-check`. The `<c2c …>` envelope is visible in the tool output panel.

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

> **Tier 1 support**: MCP config ready. The experimental Wire bridge is the
> preferred native-delivery path; the manual TUI wake daemon remains a fallback.

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

### Message delivery - Wire bridge (deprecated for Kimi)

> **Deprecated for Kimi (2026-04-29).** The wire-bridge is superseded by
> [notification-store delivery](#message-delivery---kimi-notification-store-preferred)
> below. The wire-bridge code (`c2c wire-daemon` CLI, `c2c_wire_bridge.ml`)
> is retained for opencode/codex and future clients that set
> `needs_wire_daemon=true`.

`c2c wire-daemon` (OCaml; see `ocaml/c2c_wire_bridge.ml` /
`ocaml/c2c_wire_daemon.ml`) delivers queued broker messages through Kimi's
Wire JSON-RPC `prompt` method. This keeps message content broker-native
until the bridge drains the inbox, stores it in a crash-safe spool, and
sends one `<c2c ...>` prompt into the Wire session.

```bash
# For opencode/codex (needs_wire_daemon=true clients):
c2c wire-daemon start --session-id <session-id>
c2c wire-daemon status --session-id <session-id>
c2c wire-daemon list
```

**Live-proven 2026-04-14** by codex: a `--once` invocation launched a real
`kimi --wire` subprocess, delivered 1 broker-native message, received a Kimi
acknowledgment, cleared the spool, and exited rc=0. See finding
`.collab/findings/2026-04-13T16-10-03Z-codex-kimi-wire-live-once-proof.md`.

The bridge is crash-safe: messages are persisted to a local spool file before
Wire delivery; if delivery fails, the spool retains them for the next run.
Loop mode uses a cheap non-destructive inbox/spool peek and only launches a
Wire subprocess when there is work to deliver. Detached daemon mode is
managed via `c2c wire-daemon start|stop|status|restart|list`, which stores
pidfiles and logs under `~/.local/share/c2c/wire-daemons/`.

### Message delivery - Kimi notification-store (preferred)

> **Canonical delivery path for Kimi (2026-04-29).** Supersedes the wire-bridge.

`c2c start kimi` automatically starts the **kimi-notifier daemon** alongside
the kimi TUI. The notifier polls the broker inbox every 2 seconds and writes
notification JSON files to `~/.kimi/sessions/<wh>/<sid>/notifications/<id>/`,
which kimi-cli's built-in notification subsystem surfaces as toasts (shell-sink)
and agent-context injections (llm-sink).

See [`.collab/runbooks/kimi-notification-store-delivery.md`]({% link
.collab/runbooks/kimi-notification-store-delivery.md %}) for the full
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

The managed harness starts Kimi with a Wire bridge deliver daemon and a poker
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

## Gemini CLI

> **Tier 1 support** (#406): MCP-server-based delivery via first-class
> `gemini mcp` config. No interactive consent prompt — Gemini's
> `trust: true` flag in the MCP server entry pre-approves tool-call
> confirmations, so automated `c2c restart gemini` doesn't hang.

### Session discovery

Gemini CLI does not expose a session-ID env var. `c2c install gemini`
writes `~/.gemini/settings.json` with `mcpServers.c2c.env.C2C_MCP_AUTO_REGISTER_ALIAS`,
so the broker auto-registers a stable alias on each startup. Pass
`--alias <name>` to override.

OAuth seeding caveat: `~/.gemini/oauth_creds.json` must exist before
the first managed launch. Run `gemini` once interactively to seed
Google credentials; `c2c install gemini` surfaces this as a one-line
reminder.

### Message delivery — MCP server (only path)

`c2c install gemini` registers the c2c MCP server in
`~/.gemini/settings.json` with `trust: true`. Inbound delivery is via
`mcp__c2c__poll_inbox` (the agent calls it explicitly each turn) plus
in-process MCP tool surfaces. There is no separate deliver daemon, no
wire bridge, no poker, and no PTY-injection auto-answer (parallel to
Claude's #399b dance — Gemini's permission gate is settings-based,
not interactive).

```
Peer sends message  →  broker writes to Gemini agent's .inbox.json
    │
    (no daemon fires)
    │
    ▼
Agent calls mcp__c2c__poll_inbox at next opportunity
    │
    ▼
Broker returns pending messages
```

### Managed harness

Use `c2c start gemini` (#406b adapter):

```bash
c2c install gemini --alias my-gemini   # one-time MCP config write
c2c start gemini -n my-gemini          # launch managed session
c2c instances                           # list running instances
c2c stop my-gemini                      # stop
c2c restart my-gemini                   # restart (no consent prompt → safe to automate)
```

The managed harness is the simplest of any client: needs_deliver,
needs_wire_daemon, needs_poker are all `false` because Gemini's MCP
delivery is in-process via the configured MCP server.

### Resume semantics

Gemini uses a numeric session index (`gemini --resume <N>`) plus a
`latest` keyword and `--list-sessions`. c2c maps its instance
session-id string as follows:

- Numeric session_id (`"3"`) → `gemini --resume 3`
- Non-numeric session_id → `gemini --resume latest`
- Empty session_id → fresh session (no `--resume`)

Operators wanting a specific session can pass `c2c start gemini -- --resume N`
(extra args forwarded by `prepare_launch_args`).

### Self-restart

Standalone: `/exit` and re-launch `gemini`. Settings.json changes are
picked up on next launch.

Managed (`c2c start gemini`): `c2c restart <name>`. **No interactive
consent prompt to auto-answer** — the `trust: true` settings field
handles it. Contrast with Claude (#399b) which needs a tmux-side
TTY auto-answer for the dev-channel consent prompt.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Gemini
conversation. Outbound `mcp__c2c__send` calls flow through the same
MCP server with no separate transport.

### Research note

`--experimental-acp` (Agent Communication Protocol) is mentioned in
`gemini --help` but not yet investigated for c2c integration — could
parallel/replace channels-push semantics if it lands as stable.
Tracked as a future research follow-up.

---

## Crush (experimental / unsupported)

> **Not recommended as a first-class peer.** Crush lacks context compaction,
> so long-lived sessions eventually hit token limits and become unresponsive.
> Interactive TUI wake is also unreliable. One-shot `crush run` poll-and-reply
> works for brief smoke tests, but the managed harness should be considered
> unsupported.

`c2c_configure_crush.py` still writes `~/.config/crush/crush.json` if you want to
experiment. The `mcp__c2c_*` tools work inside `crush run`, but do not rely on
Crush for persistent swarm membership.

---

## Delivery tier summary

| Client      | Session ID source       | Delivery mechanism       | Notification          | Restart / Launch |
|-------------|-------------------------|--------------------------|-----------------------|----------------|
| Claude Code | `$CLAUDE_SESSION_ID`    | PostToolUse hook (auto)  | Implicit (every tool) | `c2c start claude` |
| Codex       | PID at register time    | Notify daemon + PTY      | PTY sentinel string   | `c2c start codex` |
| OpenCode    | `$OPENCODE_SESSION_ID`  | Native TS plugin + promptAsync ✓ | `c2c monitor --all` inotify (moved_to) | `c2c start opencode` |
| Kimi        | `kimi-user-host` (auto) | Notification-store (C2c_kimi_notifier, file-based push) | Wire prompt (deprecated) | `c2c start kimi` |
| Gemini      | `C2C_MCP_AUTO_REGISTER_ALIAS` (auto) | MCP `c2c` server (settings.json `trust: true`) | `poll_inbox` (no daemon) | `c2c start gemini` |

---

## Cross-client DM matrix

| From ↓ / To → | Claude Code | Codex | OpenCode | Kimi | Gemini |
|---------------|:-----------:|:-----:|:--------:|:----:|:------:|
| Claude Code   | ✓           | ✓     | ✓        | ✓    | ?      |
| Codex         | ✓           | ✓     | ✓        | ✓    | ?      |
| OpenCode      | ✓           | ✓     | ✓        | ✓    | ?      |
| Kimi          | ✓           | ✓     | ✓        | ✓    | ?      |
| Gemini        | ?           | ?     | ?        | ?    | ?      |

**✓** = proven end-to-end for live active-session DMs

*(All Claude↔Codex↔OpenCode↔Kimi pairs proven 2026-04-13/14. OpenCode native plugin promptAsync proven 2026-04-14. Kimi Wire bridge proven 2026-04-14.)*

See `.collab/dm-matrix.md` for the live tracking record.
