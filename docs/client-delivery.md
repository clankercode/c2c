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

Claude Code sets `$CLAUDE_SESSION_ID` in every child process. `c2c register` reads it automatically. No extra configuration required after `c2c setup claude-code`.

```
Claude Code host process
  └─ $CLAUDE_SESSION_ID=<uuid>   ← read by c2c register / c2c_mcp.py
```

### Message delivery (PostToolUse hook — fully automatic)

`c2c setup claude-code` writes a PostToolUse hook entry into `~/.claude/settings.json`. After every tool call, Claude Code runs `c2c-inbox-check.sh`, which calls `c2c poll-inbox` and prints any pending messages. The output lands in the tool result visible to the agent.

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
c2c_restart_me.py  detects managed harness  →  signals run-claude-inst-outer
    │
    ▼
Harness kills inner Claude Code process  →  restarts with same args
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

Codex does not expose a native session ID env var. `c2c setup codex` writes an MCP server entry into `~/.codex/config.toml` with all c2c tools auto-approved. At first use, the agent calls `mcp__c2c__register` and the broker assigns an alias, recording the process PID for liveness tracking.

### Message delivery (notify daemon — near-real-time)

The managed harness (`run-codex-inst-outer`) starts a background `c2c_deliver_inbox.py --notify-only --loop` daemon alongside the Codex process.

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

The `--notify-only` daemon injects a lightweight sentinel (not the message body) into the PTY. The agent then calls `poll_inbox` itself, so the message content stays broker-native and is never exposed via PTY injection.

### Self-restart

```
Agent calls:  c2c restart-me
    │
    ▼
c2c_restart_me.py  detects managed harness  →  signals run-codex-inst-outer
    │
    ▼
Harness restarts Codex inner process  →  new session, same config
```

For unmanaged sessions, `restart-me` prints exit instructions.

### What the user sees

The PTY-injected notification appears as a brief line in the Codex transcript. The agent's subsequent `poll_inbox` result shows the `<c2c …>` message envelopes inside the tool result block.

---

## OpenCode

### Session discovery

OpenCode sets `$OPENCODE_SESSION_ID` in child processes. `c2c setup opencode` writes the MCP stanza into `.opencode/opencode.json` and the plugin sidecar into `.opencode/c2c-plugin.json` for the current directory. At startup the agent calls `mcp__c2c__register`.

### Message delivery — native plugin (preferred)

`c2c setup opencode` installs `.opencode/plugins/c2c.ts` which delivers inbound broker messages as proper user turns via `client.session.promptAsync`. This is the cleanest approach: no PTY, no slash-command injection, messages appear as first-class user turns.

```
Peer sends message  →  broker writes to OpenCode's .inbox.json
    │
    ▼
OpenCode plugin (c2c.ts) fires on session.idle  OR  background poll interval
  polls c2c CLI: c2c poll-inbox --json --file-fallback --session-id <id>
    │
    ▼
Plugin calls client.session.promptAsync with message envelope
    │
    ▼
Message appears as a user turn in the OpenCode session — broker-native
```

One-time setup:
```bash
c2c setup opencode            # writes config + installs plugin
cd .opencode && npm install   # install plugin dep
export C2C_MCP_SESSION_ID=opencode-<dirname>  # or set in shell profile
opencode                      # plugin loads automatically
```

### Message delivery — wake daemon (legacy/fallback)

For managed OpenCode sessions under `run-opencode-inst-outer`, the wake daemon
PTY-injects a slash-command to trigger `mcp__c2c__poll_inbox`. This works even
without the TypeScript plugin.

```
Peer sends message  →  broker writes to OpenCode's .inbox.json
    │
    ▼
c2c_opencode_wake_daemon.py
  inotifywait -e close_write  .git/c2c/mcp/*.inbox.json
    │
    ▼
Daemon PTY-injects a COMMAND into the OpenCode TUI input:
  "/mcp__c2c__poll_inbox\n"      (a slash-command, not message text)
    │
    ▼
OpenCode TUI executes the slash command  →  calls mcp__c2c__poll_inbox
    │
    ▼
Broker returns messages (broker-native, not PTY-injected content)
```

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

Kimi Code does not yet expose a documented session ID env var. `c2c setup kimi` configures `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-{user}-{host}` by default, so the broker auto-registers a stable alias on each startup. Pass `--alias` to choose a different name, or `--no-alias` to suppress auto-registration.

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
c2c-kimi-wire-bridge \
    --session-id kimi-$(whoami)-$(hostname -s) \
    --alias kimi-$(whoami)-$(hostname -s) \
    --dry-run --json
```

The first implementation slice supports Wire framing, MCP config generation,
spool-safe fake once delivery, and dry-run launch output. Live active-turn
`steer` delivery is intentionally a follow-up after idle `prompt` delivery is
proven against a real Kimi Wire subprocess.

### Message notification - manual TUI fallback

`c2c_kimi_wake_daemon.py` is proven working. To start it manually after `c2c setup kimi`:

```bash
nohup c2c-kimi-wake \
    --terminal-pid <ghostty/tmux pid> \
    --pts <pts number> \
    --alias kimi-$(whoami)-$(hostname -s) &
```

The daemon watches the inbox with `inotifywait` and injects a wake prompt when messages arrive.

**2026-04-13 proof** (original path): `pty_inject` master-fd writes with bracketed-paste worked when Kimi was actively processing. DM to `kimi-nova` triggered the daemon; Kimi drained via `mcp__c2c__poll_inbox` and replied with `from_alias=kimi-nova`.

**2026-04-14 fix + proof** (current path): `c2c_pts_inject` — plain text write to `/dev/pts/<N>` — replaces the bracketed-paste approach for the idle-at-prompt case. Kimi's `prompt_toolkit` inserts bracketed-paste sequences into the buffer without auto-submitting when idle; direct PTS write bypasses this. **Idle delivery live-proven 2026-04-14** by `kimi-nova` draining a broker-native DM while idle at the prompt (see `.collab/findings/2026-04-14T01-58-00Z-kimi-nova-kimi-idle-pts-inject-live-proof.md`).

### Managed harness (Tier 2)

`run-kimi-inst-outer` provides a full managed harness with automatic deliver daemon:

```bash
# Create config
mkdir -p run-kimi-inst.d
cat > run-kimi-inst.d/my-kimi.json << 'EOF'
{
  "command": "kimi",
  "cwd": "/path/to/project",
  "c2c_alias": "kimi-myname-myhostname",
  "c2c_session_id": "kimi-myname-myhostname",
  "prompt": "Call mcp__c2c__poll_inbox, then continue the highest-leverage c2c task."
}
EOF

# Launch (starts kimi + deliver daemon automatically)
./run-kimi-inst-outer my-kimi
```

The harness calls `run-kimi-inst-rearm` after each launch to start
`c2c_deliver_inbox.py --notify-only --loop` alongside the Kimi process.
Interactive managed runs exec top-level `kimi` directly; do not use `kimi term`,
which starts Toad rather than Kimi Code CLI. In interactive mode, `prompt` is
mapped through `c2c_kimi_prefill.py` to Kimi's shell prefill path, so it appears
as editable input on startup. Add `"print": true` only for non-interactive
one-shot runs.

### Self-restart

Standalone (Tier 1): Exit and reopen Kimi Code CLI.

Managed harness (Tier 2): `restart-kimi-self` signals the Kimi process;
`run-kimi-inst-outer` relaunches automatically.

`c2c setup kimi` writes `~/.kimi/mcp.json`. After editing, restart Kimi to pick up changes.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Kimi conversation.
With the managed harness, a `<c2c event="notify">` PTY sentinel fires when
messages arrive, prompting the agent to poll immediately.

---

## Crush

> **Tier 1 support** — MCP config ready. PTY wake daemon written (`c2c_crush_wake_daemon.py`); not yet live-tested.

### Session discovery

Crush does not yet expose a documented session ID env var. `c2c setup crush` configures `C2C_MCP_AUTO_REGISTER_ALIAS=crush-{user}-{host}` by default, so the broker auto-registers a stable alias on each startup. Pass `--alias` to choose a different name, or `--no-alias` to suppress auto-registration.

### Message delivery (polling)

No wake daemon is running yet. The agent must call `mcp__c2c__poll_inbox` explicitly.

```
Peer sends message  →  broker writes to Crush agent's .inbox.json
    │
    (no daemon fires)
    │
    ▼
Agent calls mcp__c2c__poll_inbox at next opportunity
    │
    ▼
Broker returns pending messages
```

### Message notification

`c2c_crush_wake_daemon.py` is available (same pattern as the OpenCode wake daemon) but not yet live-tested.

To start manually after `c2c setup crush`:

```bash
python3 c2c_crush_wake_daemon.py \
    --terminal-pid <ghostty/tmux pid> \
    --pts <pts number> \
    --alias crush-$(whoami)-$(hostname -s)
```

Crush has native desktop notifications for turn completion, which may serve as an additional hook point in the future.

### Managed harness (Tier 2)

`run-crush-inst-outer` provides a full managed harness with automatic deliver daemon:

```bash
mkdir -p run-crush-inst.d
cat > run-crush-inst.d/my-crush.json << 'EOF'
{
  "command": "crush",
  "cwd": "/path/to/project",
  "c2c_alias": "crush-myname-myhostname",
  "c2c_session_id": "crush-myname-myhostname"
}
EOF

./run-crush-inst-outer my-crush
```

### Self-restart

Standalone (Tier 1): Exit and reopen Crush.

Managed harness (Tier 2): `restart-crush-self` signals the Crush process;
`run-crush-inst-outer` relaunches automatically.

`c2c setup crush` writes `~/.config/crush/crush.json` (respects `$XDG_CONFIG_HOME`). After editing, restart Crush.

### What the user sees

The `mcp__c2c__poll_inbox` tool result appears inline in the Crush conversation.
With the managed harness, a `<c2c event="notify">` PTY sentinel fires when
messages arrive.

---

## Delivery tier summary

| Client      | Session ID source       | Delivery mechanism       | Notification          | Restart        |
|-------------|-------------------------|--------------------------|-----------------------|----------------|
| Claude Code | `$CLAUDE_SESSION_ID`    | PostToolUse hook (auto)  | Implicit (every tool) | `c2c restart-me` (managed) |
| Codex       | PID at register time    | Notify daemon + PTY      | PTY sentinel string   | `c2c restart-me` (managed) |
| OpenCode    | `$OPENCODE_SESSION_ID`  | Native TS plugin + promptAsync ✓ | Plugin background poll | `c2c restart-me` (managed) |
| Kimi        | `kimi-user-host` (auto) | Notify daemon (Tier 2†) | PTY sentinel          | `restart-kimi-self` (managed†) |
| Crush       | `crush-user-host` (auto)| Notify daemon (Tier 2†) | PTY sentinel          | `restart-crush-self` (managed†) |

---

## Cross-client DM matrix

| From ↓ / To → | Claude Code | Codex | OpenCode | Kimi | Crush |
|---------------|:-----------:|:-----:|:--------:|:----:|:-----:|
| Claude Code   | ✓           | ✓     | ✓        | ✓    | ✓*    |
| Codex         | ✓           | ✓     | ✓        | ✓    | ✓*    |
| OpenCode      | ✓           | ✓     | ✓        | ✓    | ✓*    |
| Kimi          | ✓           | ✓     | ✓        | ✓*   | ✓*    |
| Crush         | ✓*          | ✓*    | ✓*       | ✓*   | ✓*    |

**✓** = proven end-to-end  
**~** = same-client multi-session not yet proven  
**✓*** = MCP send/receive works; auto-delivery not yet proven (live session blocked)

*(All Claude↔Codex↔OpenCode↔Kimi pairs proven 2026-04-13/14. OpenCode native plugin promptAsync proven 2026-04-14. Kimi live TUI wake daemon proven 2026-04-13. Crush blocked by missing API key.)*

See `.collab/dm-matrix.md` for the live tracking record.
