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
  └─ $CLAUDE_SESSION_ID=<uuid>   ← read by c2c register / c2c_mcp.py
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
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  detects managed harness  →  signals c2c start claude outer
    │
    ▼
Outer process kills inner Claude Code process  →  restarts with same args
    │
    ▼
New Claude Code session: picks up updated ~/.claude.json / settings.json
```

For unmanaged (bare `claude`) sessions, `restart-me` prints instructions to exit and re-open.

### What the user sees

In the Claude Code transcript, delivered messages appear inline as tool results labelled `c2c-inbox-check`. The `<c2c …>` envelope is visible in the tool output panel.

---

## Codex

### Session discovery

Codex does not expose a native session ID env var. `c2c install codex` writes only shared MCP config into `~/.codex/config.toml`: broker root, default rooms, and auto-approved c2c tools. Managed `c2c start codex` sessions export `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` at launch; unmanaged sessions can use `c2c init --client codex` or call `register` directly.

### Message delivery (preferred: XML sideband into normal TUI)

When the forked Codex binary supports `--xml-input-fd`, `c2c start codex` creates a sideband pipe, launches `codex --xml-input-fd 3`, and runs `c2c_deliver_inbox.py --xml-output-fd ... --loop` alongside it.

```
Peer sends message  →  broker writes to Codex's .inbox.json
    │
    ▼
c2c_deliver_inbox.py daemon
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

On stock Codex, or when `--xml-input-fd` is unavailable, the managed harness starts `c2c_deliver_inbox.py --notify-only --loop` alongside the Codex process.

```
Peer sends message  →  broker writes to Codex's .inbox.json
    │
    ▼
c2c_deliver_inbox.py daemon
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
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  detects managed harness  →  signals c2c start codex outer
    │
    ▼
Outer process restarts Codex inner process  →  new session, same config
```

For unmanaged sessions, `restart-me` prints exit instructions.

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

OpenCode sets `$OPENCODE_SESSION_ID` in child processes. `c2c install opencode` writes the MCP stanza into `.opencode/opencode.json` and the plugin sidecar into `.opencode/c2c-plugin.json` for the current directory. At startup the agent calls `mcp__c2c__register`.

### Message delivery — native plugin (preferred)

`c2c install opencode` installs `.opencode/plugins/c2c.ts` which delivers inbound broker messages as proper user turns via `client.session.promptAsync`. This is the cleanest approach: no PTY, no slash-command injection, messages appear as first-class user turns.

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
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  signals opencode managed harness  →  restarts TUI
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

### Message delivery - Wire bridge (experimental preferred)

`c2c-kimi-wire-bridge` delivers queued broker messages through Kimi's Wire
JSON-RPC `prompt` method. This keeps message content broker-native until the
bridge drains the inbox, stores it in a crash-safe spool, and sends one
`<c2c ...>` prompt into the Wire session.

```bash
# Preview launch config without running Kimi:
c2c-kimi-wire-bridge \
    --session-id kimi-$(whoami)-$(hostname -s) \
    --alias kimi-$(whoami)-$(hostname -s) \
    --dry-run --json

# Deliver any queued broker messages and exit (requires kimi in PATH):
c2c-kimi-wire-bridge \
    --session-id kimi-$(whoami)-$(hostname -s) \
    --alias kimi-$(whoami)-$(hostname -s) \
    --once --json

# Run persistently in the foreground; starts Kimi Wire only when work is queued:
c2c-kimi-wire-bridge \
    --session-id kimi-$(whoami)-$(hostname -s) \
    --alias kimi-$(whoami)-$(hostname -s) \
    --loop --interval 5

# Preferred detached daemon manager:
c2c wire-daemon start --session-id kimi-$(whoami)-$(hostname -s)
c2c wire-daemon status --session-id kimi-$(whoami)-$(hostname -s)
```

**Live-proven 2026-04-14** by codex: `--once` launched a real `kimi --wire`
subprocess, delivered 1 broker-native message, received a Kimi acknowledgment,
cleared the spool, and exited rc=0. See finding
`.collab/findings/2026-04-13T16-10-03Z-codex-kimi-wire-live-once-proof.md`.

The bridge is crash-safe: messages are persisted to a local spool file before
Wire delivery; if delivery fails, the spool retains them for the next run.
Loop mode (`--loop`) uses a cheap non-destructive inbox/spool peek and only
launches a Wire subprocess when there is work to deliver. Detached daemon mode
can be managed directly with `c2c wire-daemon start|stop|status|restart|list`,
which stores pidfiles and logs under `~/.local/share/c2c/wire-daemons/`.
Use raw `--daemon --pidfile` flags only when you need custom paths.

### Message notification - Wire bridge (preferred)

Use `c2c wire-daemon start` (above). The Wire bridge delivers messages via `kimi --wire` JSON-RPC with no PTY injection.

**Deprecated:** `c2c_kimi_wake_daemon.py` PTY wake path — superseded by Wire bridge.

**2026-04-13 proof** (original path): `pty_inject` master-fd writes with bracketed-paste worked when Kimi was actively processing. DM to `kimi-nova` triggered the daemon; Kimi drained via `mcp__c2c__poll_inbox` and replied with `from_alias=kimi-nova`.

**2026-04-14 correction** (current path): direct writes to
`/dev/pts/<N>` are display-side writes, not keyboard input. They can make text
appear in Kimi without submitting a prompt. Kimi wake now uses the master-side
`pty_inject` backend with a longer default submit delay (1.5s), so Enter lands
after the bracketed paste has been accepted. See
`.collab/findings/2026-04-13T16-12-18Z-codex-kimi-pts-slave-write-not-input.md`.

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
With the Wire bridge, messages arrive as first-class `kimi --wire` prompts — no
PTY injection required.

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
| Kimi        | `kimi-user-host` (auto) | Wire bridge (`kimi --wire` JSON-RPC) | Wire prompt | `c2c start kimi` |

---

## Cross-client DM matrix

| From ↓ / To → | Claude Code | Codex | OpenCode | Kimi |
|---------------|:-----------:|:-----:|:--------:|:----:|
| Claude Code   | ✓           | ✓     | ✓        | ✓    |
| Codex         | ✓           | ✓     | ✓        | ✓    |
| OpenCode      | ✓           | ✓     | ✓        | ✓    |
| Kimi          | ✓           | ✓     | ✓        | ✓    |

**✓** = proven end-to-end for live active-session DMs

*(All Claude↔Codex↔OpenCode↔Kimi pairs proven 2026-04-13/14. OpenCode native plugin promptAsync proven 2026-04-14. Kimi Wire bridge proven 2026-04-14.)*

See `.collab/dm-matrix.md` for the live tracking record.
