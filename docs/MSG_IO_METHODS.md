---
layout: page
title: Message I/O Methods
permalink: /msg-io-methods/
---

# c2c Message I/O Methods Reference

A single reference tracking every delivery method in c2c: how messages
get from one agent to another, which clients support each method, what
implements it, and where the sharp edges are.

Last updated: 2026-07-17 (kimi re-enabled: B146 reverted; REST delivery)

---

## Summary Table

| # | Method | One-liner | Claude Code | Codex | Pi Agent | OpenCode | Kimi | Grok | Status |
|---|--------|-----------|:-----------:|:-----:|:--------:|:--------:|:----:|:----:|--------|
| 1 | [MCP Channel Notifications](#1-mcp-channel-notifications) | Server pushes messages into the chat UI via JSON-RPC notification | Gated | No | No MCP | No | No | No | Experimental / gated behind dev flag |
| 2 | [PostToolUse Hook](#2-posttooluse-hook) | Host hooks drain inboxes into `additionalContext` at tool/turn boundaries | Yes | Yes (vanilla + managed fallback) | No | No | No | No | Working (primary for Claude Code; Codex vanilla/fallback only) |
| 2b | [Codex app-server inject + gated auto-turn](#2b-codex-app-server-inject--gated-auto-turn) | Managed Codex: arrival-time inject + idle auto-turn over authenticated app-server | No | Yes (managed ≥0.144) | No | No | No | No | **Primary for managed Codex** (B131); hooks fall back |
| 3 | [PTY Injection](#3-pty-injection) | Bracketed paste via pty_inject into terminal master fd | Deprecated | Deprecated sentinel | No | Fallback | No | No | Legacy/fallback only; Kimi uses REST prompt injection |
| 4 | [History.jsonl Injection](#4-historyjsonl-injection) | Appends a user-message entry to the session transcript file | Partial | No | No | No | No | No | Experimental; not real-time |
| 5 | [poll_inbox Tool](#5-poll_inbox-tool) | Pull-based MCP/CLI tool that drains and returns pending messages | Yes | Yes | Yes (CLI) | Yes | Yes | Yes (CLI) | Working (universal baseline) |
| 6 | [Wake Daemon](#6-wake-daemon) | inotify watches inbox and wakes/delivers to idle agents | Yes | Legacy / hook-wake | Yes (`pi-c2c`) | Yes | Yes | Monitor | Working for Pi/OpenCode; Grok uses Monitor+`c2c monitor`; legacy for Codex PTY sentinel |
| 7 | [Kimi Wire Bridge](#7-kimi-wire-bridge) | Delivers broker messages through Kimi's Wire JSON-RPC `prompt` method | No | No | No | No | Deprecated | No | Deprecated; REST prompt injection is preferred |
| 8 | [OpenCode Native Plugin](#8-opencode-native-plugin) | TypeScript plugin + alias-scoped `c2c monitor`, delivers via `promptAsync` | No | No | No | Yes | No | No | Proven; preferred for OpenCode |
| 9 | [Kimi REST Prompt Injection](#9-kimi-rest-prompt-injection) | POSTs each DM as a user prompt to the Kimi Code local REST server | No | No | No | No | Yes | No | Primary for Kimi |

> **agy (Google Antigravity)** — new client, 2026-07-14; not in the 0.12.0
> release. Not broken out as its own column above to keep these matrices
> aligned. agy **mirrors the Grok / CLI-first row**: no MCP, `poll_inbox` /
> `c2c poll-inbox` as the universal baseline and a persistent **Monitor** on
> `c2c monitor`. Beyond Grok, agy adds a **managed agentapi wake path** — the
> `c2c start agy` deliver-watch sidecar (`c2c_agy_deliver.ml`) injects standard
> `<c2c event="message">` envelopes via `agy agentapi send-message`
> (`ANTIGRAVITY_LS_ADDRESS`). Managed `c2c start agy` **is real** (via
> `AgyAdapter`), unlike Grok's deferred managed start. Install is CLI-first
> (`c2c install agy`; skill + SessionStart/PostToolUse/Stop hooks under
> `~/.gemini/`). See [Per-Client Delivery § Antigravity (agy)](/client-delivery/#antigravity-agy).

---

## Detailed Method Descriptions

### 1. MCP Channel Notifications

**`notifications/claude/channel`** -- Server pushes messages directly into the
agent's chat UI as visible user messages via an MCP JSON-RPC notification.

#### How it works

The c2c MCP server (OCaml) declares `experimental.claude/channel: {}` as a
server capability in its `initialize` response. When a message arrives in the
session inbox, the server emits a `notifications/claude/channel` JSON-RPC
notification with the message content and metadata. Claude Code's SDK bridge
(`extractInboundMessageFields`) renders it as a visible message in the chat UI.

A background Lwt thread in the MCP server polls the inbox file every 1 second
and emits channel notifications for any new messages (continuous delivery, not
just post-initialize).

#### Notification shape

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/claude/channel",
  "params": {
    "content": "message text from peer",
    "meta": {
      "from": "storm-ember",
      "to": "storm-storm"
    }
  }
}
```

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Gated | Requires `--dangerously-load-development-channels server:c2c`. Standard Claude Code does NOT declare `experimental.claude/channel` in its `initialize` request, so auto-drain never fires. |
| Codex | No | No MCP channel notification support. No equivalent mechanism. |
| Pi Agent | No | No MCP channel notification support; `pi-c2c` uses CLI polling and inbox watching. |
| OpenCode | No | No MCP channel notification support. Closest equivalent is `/tui/show-toast` HTTP API (ephemeral, 5s, not in message history). |
| Kimi | No | No MCP channel notification support. |

#### Key files

| File | Role |
|------|------|
| `ocaml/c2c_mcp.ml` | `channel_notification` function, server capability declaration, initialize response |
| `ocaml/server/c2c_mcp_server_inner.ml` | Channel capability negotiation, `channel_delivery_enabled()`, Lwt inbox watcher, auto-drain after initialize |
| `ocaml/server/c2c_mcp_server.ml` | Thin standalone binary entrypoint that calls the inner server implementation |
| `ocaml/test/test_c2c_mcp.ml` | Unit test validating notification shape |
| `docs/channel-notification-impl.md` | Implementation spec |

#### Limitations

- Standard Claude Code never declares `experimental.claude/channel` in its
  `initialize` -- so even with `C2C_MCP_AUTO_DRAIN_CHANNEL=1`, the capability
  check fails and auto-drain does not fire.
- Requires the `--dangerously-load-development-channels` launch flag, which is
  not suitable for production use.
- No other client (Codex, Pi Agent, OpenCode, Kimi) supports this mechanism.
- Auto-drain and continuous delivery are implemented server-side but remain
  effectively dormant until Claude Code ships native channel support.

#### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | `1` (server default; `c2c install` writes `0`) | Enable post-initialize inbox drain + channel notification emission. Only effective when the client declares `experimental.claude/channel`. |
| `C2C_MCP_CHANNEL_DELIVERY` | `1` (when set by `c2c install claude`) | Controls whether the continuous inbox watcher emits channel notifications. |

---

### 2. PostToolUse Hook

**Auto-delivery via host hooks** -- Claude Code and Codex both run c2c hook
commands from the host's hook system and surface drained broker messages as
`hookSpecificOutput.additionalContext` in the agent transcript. For managed
Codex on a supported binary this is the **fallback** path; see
[§2b](#2b-codex-app-server-inject--gated-auto-turn) for the primary app-server
method.

#### How it works

Claude Code and Codex use different hook event sets, but the delivery shape is
similar: the hook receives a JSON payload on stdin, resolves the session id,
drains the broker inbox, and returns a JSON object containing
`hookSpecificOutput.additionalContext`.

For Claude Code, `c2c install claude` installs two things:

1. A hook script at `~/.claude/hooks/c2c-inbox-check.sh`.
2. A `PostToolUse` entry in `~/.claude/settings.json` that runs the script
   after every tool call (matcher: `.*`).

The hook script calls `c2c-inbox-hook-ocaml`. The hook reads Claude's
`session_id` from the PostToolUse stdin JSON payload, drains non-deferrable
messages from the repo broker inbox plus the global session-addressed broker
(`C2C_SESSIONS_BROKER_ROOT` override, otherwise `$HOME/.c2c/sessions/broker`),
and emits one `hookSpecificOutput.additionalContext` JSON object. Message envelopes and the
once-per-session cold-boot context are merged into that single context payload.

For Codex, `c2c install codex` writes a managed, pre-trusted hooks block to
`~/.codex/config.toml`. The block runs `c2c hook codex` for
`UserPromptSubmit`, `PostToolUse`, `SessionStart`, and `SessionEnd`:

- `SessionStart` emits onboarding/wake context and performs a full inbox drain.
- `UserPromptSubmit` drains all pending messages at the next user-turn boundary,
  including deferrable messages.
- `PostToolUse` drains push-eligible/non-deferrable messages mid-turn, mirroring
  the Claude Code active-tool-call path.
- `SessionEnd` cleans up vanilla per-thread hook registrations.

Vanilla/unmanaged Codex sessions auto-register on the first hook fire and receive
through these installed hooks. Managed `c2c start codex` sessions on a supported
Codex (codex-cli ≥ 0.144) instead receive arrival-time over the app-server path
(shipped, B131 — see [Per-Client Delivery § Codex](/client-delivery/#codex));
managed sessions on an older Codex, or after an app-server startup failure, fall
back automatically to the installed hooks at hook boundaries, with their stable
c2c session id resolved from the managed thread mapping. Explicit polling
remains the universal fallback. The hook command is intentionally
fail-open: hook errors exit `0` with empty output so a c2c issue does not break
the Codex turn.

```
Agent/host reaches a hook boundary
    |
    v
Claude Code PostToolUse hook or Codex UserPromptSubmit/PostToolUse hook fires
    |
    v
c2c-inbox-check.sh / c2c hook codex  -->  broker drains inboxes
    |
    v
additionalContext visible in the agent transcript:
  <c2c event="message" from="storm-echo" to="storm-beacon">
    hello from peer
  </c2c>
```

Latency: bounded by how quickly the recipient reaches the next hook boundary.
Active Claude Code and hook-path Codex sessions usually receive messages on
the next tool call; Codex also drains at user-turn boundaries. Managed Codex
sessions on a supported Codex are not bounded by hook boundaries at all: the
app-server path (shipped, B131) injects mail into the thread's model-visible
history on arrival. Idle agents on the hook path that are not reaching any
hook boundary still need an idle-session bridge or manual polling.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes | Primary delivery mechanism. Installed by `c2c install claude`. |
| Codex | Yes | **Vanilla primary / managed fallback.** `c2c install codex` installs pre-trusted hooks that run `c2c hook codex` and deliver via `additionalContext` — hook-boundary, not arrival-time. Managed sessions on a supported Codex get [app-server delivery](#2b-codex-app-server-inject--gated-auto-turn) instead (arrival-time, draft-safe; shipped, B131); older Codex or app-server startup failure falls back here automatically. Explicit polling remains the portable fallback. |
| Pi Agent | No | Pi Agent uses the `pi-c2c` extension rather than host hooks. |
| OpenCode | No | OpenCode uses its native TypeScript plugin instead. |
| Kimi | No | Kimi uses REST prompt injection instead. |

#### Key files

| File | Role |
|------|------|
| `ocaml/cli/c2c_setup.ml` | Writes install-time client config. For Claude Code, registers the PostToolUse hook in `~/.claude/settings.json`; for Codex, writes the managed hooks block to `~/.codex/config.toml`. |
| `~/.claude/hooks/c2c-inbox-check.sh` | Claude Code hook script (installed by `c2c install claude`) |
| `ocaml/tools/c2c_inbox_hook.ml` | Dedicated Claude Code PostToolUse hook binary that drains repo/global inboxes and emits `additionalContext` |
| `ocaml/tools/c2c_cold_boot_context.ml` | Once-per-session cold-boot context merged into the Claude Code inbox hook payload |
| `ocaml/cli/c2c_codex_hooks.ml` | Renders and verifies the Codex `UserPromptSubmit`/`PostToolUse`/`SessionStart`/`SessionEnd` hooks block and trust hashes |
| `ocaml/cli/c2c_hook_cmd.ml` | Implements `c2c hook codex`: auto-registers vanilla sessions, drains inboxes, and emits Codex `additionalContext` |

#### Limitations

- Hook delivery only fires when the host reaches a hook boundary. A truly idle
  session may not receive messages until it resumes tool use, receives user
  input, or polls explicitly.
- Claude Code and Codex hook schemas are host-specific. Other clients use their
  own delivery integrations (`pi-c2c`, OpenCode plugin, Kimi REST prompt injection).
- The Claude Code hook bounds stdin scanning to the prefix needed to find
  `session_id`; malformed or oversized trailing hook payload data does not force
  a full JSON parse before delivery.
- The Codex hook is deliberately fail-open and time-capped. This protects Codex
  turns from c2c failures, but also means a hook failure can silently defer
  delivery until a later hook boundary or manual poll.

---

### 2b. Codex app-server inject + gated auto-turn

**Primary delivery for managed Codex on a supported binary (codex-cli ≥ 0.144)** —
arrival-time injection into the thread's model-visible history plus a gated
auto-turn for eligible local mail. Distinct from host hooks (method 2).

#### How it works

Managed `c2c start codex` / `c2c new codex` launch `codex app-server` on an
**authenticated loopback WebSocket** (`--ws-auth capability-token`) with the
stock remote TUI attached. The managed supervisor drives the T003 ingress +
T007 auto-turn pipeline while the frontend is attached:

1. Inbound c2c mail is injected on arrival as DATA (`thread/inject_items`) —
   draft-safe; the composer is frontend-only state the app-server cannot touch.
2. Eligible **local-broker** mail starts one model turn when the thread is
   **explicitly idle** and DND is off (remote/`@host`/`#` senders and
   active/unknown status fail closed to queued).
3. Idle auto-turn fires **immediately** (B168); inject failures and
   `Turn_failed` batches force-retry / re-batch after ~**2 minutes**
   (`stale_inbox_threshold_s` = 120).
4. Cross-repo sessions-broker mail is inject-only (B141) — never starts a turn.
5. Older Codex or app-server startup failure falls back automatically to
   method 2 (hooks).

Identity: after a successful start the launcher binds the banner alias into the
broker before first interaction (B172); hooks inherit the launcher session id
via `C2C_CODEX_APPSERVER_SESSION` (B166/B137) so there is a single identity.

Full contract: [Per-Client Delivery § Codex](/client-delivery/#codex).

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Codex (managed, ≥0.144) | **Yes — Primary** | Shipped B131; `delivery_mode=app-server` while `online-attached`. |
| Codex (vanilla / older / force-hooks) | No | Use method 2 (hooks) + optional wake inject. |
| Claude Code / Pi / OpenCode / Kimi / Grok | No | — |

#### Limitations

- Requires codex-cli ≥ 0.144 and a successful app-server start.
- Auto-turn is local-broker only; remote-origin mail is data-only.
- Message content never resolves approvals (B098 bus-never-RPC).

---

### 3. PTY Injection

**Bracketed paste via `pty_inject` into the terminal master fd** -- Writes
text directly into a running terminal session's input stream using
`pidfd_getfd()` to obtain the PTY master file descriptor.

#### How it works

An external `pty_inject` binary (compiled from the `meta-agent` repo) uses
`pidfd_getfd()` with `cap_sys_ptrace=ep` capabilities to obtain the PTY master
fd from a target process. It then writes the payload using bracketed paste
escape sequences (`\x1b[200~` ... `\x1b[201~`) followed by Enter (`\r`) as a
separate write with an optional submit delay.

For sentinel mode (legacy Codex and OpenCode fallback), the injected text tells
the agent to call `poll_inbox` -- the message body stays in the broker. For
full-delivery mode (legacy), the message content itself is injected.

Kimi historically required master-side injection with a longer submit delay
because direct `/dev/pts/<N>` slave-side writes display text without submitting
it as keyboard input. Current Kimi delivery uses REST prompt injection
instead of PTY injection.

#### Client support

| Client | Supported | Mode | Notes |
|--------|-----------|------|-------|
| Claude Code | Deprecated | Full or sentinel | Legacy path. Superseded by PostToolUse hook. Still available via `claude_send_msg.py`. |
| Codex | Deprecated | Sentinel | Superseded by Codex hooks installed by `c2c install codex`. Older managed-session/watch paths used a sentinel that triggered `poll_inbox`. |
| Pi Agent | No | — | Uses `pi-c2c` (`fs.watch` + CLI drain + `pi.sendMessage`), not PTY injection. |
| OpenCode | Fallback | Sentinel (slash-command) | Wake daemon injects `/mcp__c2c__poll_inbox`. Superseded by native TypeScript plugin. |
| Kimi | No | — | Superseded by REST prompt injection (`C2c_kimi_notifier`). |

#### Key files

| File | Role |
|------|------|
| `c2c-deliver-inbox` (OCaml binary, installed by `just install-all`) | Legacy watcher: watches inbox via inotifywait and can deliver via PTY sentinel or full mode. The legacy `c2c_deliver_inbox.py` is only used as a fallback if the binary is missing. |
| `ocaml/c2c_poker.ml` (`C2c_poker`) | Generic PTY heartbeat poker; injects `<c2c event="heartbeat">` envelopes to keep sessions alive. The Python `c2c_poker.py` is a fallback. |
| `c2c_inject.py` | Legacy one-shot PTY injection with bracketed paste, keycode support, and history.jsonl fallback. Deprecated. |
| `claude_send_msg.py` | Legacy: sends PTY-injected messages to Claude Code sessions |
| External: `pty_inject` binary | Hardcoded at `/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject`. Requires `cap_sys_ptrace=ep`. |

#### Limitations

- Requires the terminal PID and PTY master fd -- goes stale on restart.
- Does not work over SSH (PTY master not accessible server-side).
- Fragile: depends on the terminal emulator (works with Ghostty, tmux, etc.)
  and the exact process tree layout.
- Writing to `/dev/pts/<N>` (slave side) is display output, not keyboard
  input -- Kimi and OpenCode require master-side injection.
- Not cross-platform; Linux-only (`pidfd_getfd()`, `/proc` filesystem).
- For legacy Codex sentinel delivery, the injected text is only a wake marker --
  the agent must still call `poll_inbox` to get the actual message content.
  Current Codex installs prefer host hooks; Kimi no longer uses this path at all.

---

### 4. History.jsonl Injection

**Appends a user-message JSON entry to the session's transcript file** --
Writes directly to Claude Code's `history.jsonl` so the message appears in
the conversation history on next reload.

#### How it works

`c2c_inject.py` (method `history`) constructs a well-formed JSONL entry
matching Claude Code's transcript format (with `parentUuid`, `promptId`,
`uuid`, `timestamp`, `type: "user"`, `userType: "external"`, etc.) and
appends it to the session's transcript file. It searches multiple transcript
locations: `~/.claude/projects/<slug>/<session>.jsonl` and
`~/.claude-shared/projects/<slug>/<session>.jsonl`.

The injected message appears in the session history but is not visible in
real-time in the chat UI -- the agent sees it only on next session reload or
context refresh.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Partial | Works for appending to transcript, but not visible in real-time UI. Only seen on reload. |
| Codex | No | No documented transcript file format to target. |
| Pi Agent | No | Pi Agent receives through the extension API, not transcript-file mutation. |
| OpenCode | No | No documented transcript file injection path. |
| Kimi | No | No documented transcript file injection path. |

#### Key files

| File | Role |
|------|------|
| `c2c_inject.py` | `inject_via_history()` function; constructs and appends transcript JSONL entry |
| `c2c_inject.py --method history` | Standalone experimental path for direct history.jsonl injection; older `send_to_session.py` references are from deprecated/scratch worktrees, not the current repo root. |

#### Limitations

- Not real-time: the recipient only sees the injected message on next session
  reload, not during active conversation.
- Claude Code-specific transcript format; fragile across version upgrades.
- Invisible in SSH-based Claude Code UI (appears only in transcript file, not
  rendered in the terminal).
- No locking or concurrency safety when appending.
- Experimental status; not on the primary delivery path for any client.

---

### 5. poll_inbox Tool

**Pull-based MCP tool** -- The agent explicitly calls `mcp__c2c__poll_inbox`
to drain and return all pending messages from its broker inbox.

#### How it works

The `poll_inbox` tool is exposed by the OCaml MCP server via stdio JSON-RPC.
When called, it:

1. Acquires a POSIX `lockf` on the session's inbox lock file.
2. Reads the inbox JSON array.
3. Archives all messages to `<broker_root>/archive/<session_id>.jsonl`
   (append-only, for history).
4. Writes an empty array back to the inbox file (atomic temp-file +
   `rename`).
5. Returns the drained messages as the tool result.

Messages are returned in `<c2c event="message" from="..." to="...">` envelope
format. A companion tool `peek_inbox` performs the same read without draining
(non-destructive).

This is the universal baseline: every client that has MCP support can use
`poll_inbox` regardless of whether auto-delivery is configured.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes | Manual fallback; automatic PostToolUse delivery uses `c2c-inbox-hook-ocaml` directly. |
| Codex | Yes | Manual fallback; automatic Codex hook delivery drains the broker directly through `c2c hook codex`. |
| Pi Agent | Yes | `pi-c2c` drains through `c2c poll-inbox` via the CLI. |
| OpenCode | Yes | Called by native TypeScript plugin or wake daemon. |
| Kimi | Yes | Called manually or triggered by Wire bridge / wake daemon. |

#### Key files

| File | Role |
|------|------|
| `ocaml/c2c_mcp.ml` | `poll_inbox` and `peek_inbox` tool definitions; `drain_inbox`, `archive_messages` implementations |
| `ocaml/server/c2c_mcp_server_inner.ml` | MCP server main loop; routes `tools/call` for `poll_inbox` |
| `ocaml/cli/c2c.ml` | `c2c poll-inbox` CLI command (non-MCP fallback) |

#### Limitations

- Pull-based: the agent must actively call the tool. Without a wake mechanism
  (hook, daemon, plugin), messages sit in the inbox until the next poll.
- Draining is destructive: once polled, messages are removed from the inbox.
  Use `peek_inbox` for non-destructive checks.
- Archives are append-only and grow without bound unless pruned externally.
  Use `c2c history` to review past messages.

---

### 6. Wake Daemon

**inotifywait-based daemon that PTY-injects a poll sentinel to wake idle
sessions** -- Bridges the gap between broker-native messaging and agents that
only receive messages when actively calling tools.

#### How it works

Each wake daemon follows the same pattern:

1. Watches the session's inbox file using `inotifywait -e close_write,modify,delete,moved_to`
   (`moved_to` required because the broker writes inboxes atomically via tmp+rename).
2. When the inbox is modified (message enqueued), checks that it is non-empty.
3. PTY-injects a client-appropriate sentinel or wake prompt via the
   `pty_inject` binary (master-side bracketed paste + Enter).
4. The injected text tells the agent to call `mcp__c2c__poll_inbox`.
5. Respects a configurable `--min-inject-gap` to avoid spamming the terminal.

There are per-client variants because each client needs slightly different
injection text and PTY coordination:

| Daemon | Client | Injection text |
|--------|--------|----------------|
| `c2c_claude_wake_daemon.py` (**deprecated**) | Claude Code | Wake prompt asking the agent to call `poll_inbox` |
| `c2c-deliver-inbox --notify-only` (legacy OCaml path) | Codex | `<c2c event="message_pending">poll mcp__c2c__poll_inbox</c2c>` sentinel; superseded by Codex hooks |
| `pi-c2c` extension | Pi Agent | `fs.watch` inbox watcher drains via `c2c poll-inbox` and injects with `pi.sendMessage` |
| `c2c_opencode_wake_daemon.py` (**deprecated**) | OpenCode | Superseded by TypeScript plugin + `c2c monitor` subprocess |
| `c2c_kimi_wake_daemon.py` (**deprecated**) | Kimi | Superseded by `C2c_kimi_notifier` (REST prompt injection) |
| `c2c_crush_wake_daemon.py` (**deprecated**) | Crush | Unreliable; Crush not a first-class peer |

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | Yes (gap) | PostToolUse hook covers active tool calls. AFK gap (idle session) has no non-PTY fix yet; `c2c_claude_wake_daemon.py` deprecated. |
| Codex | Hook-fallback only | PTY sentinel deprecated. Managed supported Codex uses app-server (no wake inject). Hook-mode managed/vanilla may use tmux/herdr wake inject (`hooks+wake`). |
| Pi Agent | Yes ✓ | `pi-c2c` watches inbox changes with `fs.watch`, with a 60s safety-net poll. |
| OpenCode | Yes ✓ | TypeScript plugin (`c2c.ts`) delivers via alias-scoped `c2c monitor --alias <session>` → `promptAsync`. No PTY; not `--all`. |
| Kimi | Yes ✓ | REST prompt injection (`C2c_kimi_notifier`). Preferred over deprecated PTY wake. |
| Grok | Monitor | Prefer persistent Monitor on `c2c monitor` (CLI-first; no managed `c2c start grok`). |
| Crush | Deprecated | Unreliable; Crush lacks context compaction. |

#### Key files

| File | Role |
|------|------|
| `c2c_claude_wake_daemon.py` | Claude Code PTY wake — **deprecated** |
| `c2c-deliver-inbox` (OCaml binary) | Legacy Codex PTY sentinel watcher (with `--notify-only --loop`); Python `c2c_deliver_inbox.py` is a fallback |
| `c2c_opencode_wake_daemon.py` | OpenCode PTY wake — **deprecated**; use TypeScript plugin |
| `c2c_kimi_wake_daemon.py` | Kimi PTY wake — **deprecated**; use `C2c_kimi_notifier` (REST prompt injection) |
| `c2c_crush_wake_daemon.py` | Crush PTY wake — **deprecated** |
| `ocaml/c2c_poker.ml` (`C2c_poker`) | Shared PTY injection helper used by all daemons; Python `c2c_poker.py` is a fallback |

#### Limitations

- Requires PTY coordinates (terminal PID and pts number) -- goes stale on
  restart unless the managed harness re-arms the daemon.
- Does not work over SSH.
- Minimum injection gap prevents spam but adds latency (default 15s for
  most clients).
- The sentinel/wake prompt is injected into the terminal input stream, which
  can be disruptive if the agent is mid-prompt or mid-output.
- Each client needs a separate daemon variant due to different TUI behaviors.

---

### 7. Kimi Wire Bridge

> **Deprecated for Kimi (2026-04-29).** The [Kimi REST prompt injection](#9-kimi-rest-prompt-injection) (Section 9) is the preferred path. The wire-bridge code (`c2c_wire_bridge.ml`) is retained for opencode/codex and future clients that set `needs_wire_daemon=true`.

**Delivers broker messages through Kimi's Wire JSON-RPC `prompt` method** --
A native delivery path that avoids all PTY hacking by using Kimi's built-in
Wire protocol.

#### Status: REMOVED

The Kimi wire-bridge path was deprecated and removed in the
kimi-wire-bridge-cleanup slice. It was replaced by `C2c_kimi_notifier`
(REST prompt injection into the Kimi Code local server) which avoids the
dual-agent registration bug that plagued the wire-bridge approach.

See [Section 9](#9-kimi-rest-prompt-injection) for the replacement mechanism.

#### Historical key files (removed)

| File | Role |
|------|------|
| ~~`ocaml/c2c_wire_daemon.ml`~~ | Removed — kimi-only wire daemon lifecycle |
| ~~`c2c wire-daemon` CLI group~~ | Removed — kimi-only daemon management |
| `deprecated/c2c_kimi_wire_bridge.py` / `c2c_wire_daemon.py` | Legacy Python; still present but unused |

#### Limitations
- Wire subprocess is started per delivery batch, not kept alive between polls
  (loop mode only launches Wire when there is work).
- Spool file retains messages on delivery failure for retry, but there is no
  automatic retry backoff.
- **For Kimi: use Section 9 (REST prompt injection) instead.**

---

### 8. OpenCode Native Plugin

**TypeScript plugin that polls the broker and delivers via `promptAsync`** --
Messages appear as first-class user turns in the OpenCode session without any
PTY injection.

#### How it works

`c2c install opencode` installs a TypeScript plugin at
`.opencode/plugins/c2c.ts` under the target project (symlinked to
`data/opencode-plugin/c2c.ts` in a dev checkout, or written from the embedded
blob in a binary-only install). The plugin:

1. Spawns an **alias-scoped** `c2c monitor --alias <session>` subprocess (not
   `--all`) and also runs a safety-net background poll.
2. On inbox activity, calls the c2c CLI
   (`c2c poll-inbox --json --file-fallback --session-id <id>`) to drain the
   broker inbox.
3. For each message, calls `client.session.promptAsync` to inject it as a
   proper user turn.
4. The message appears natively in the OpenCode session -- no PTY, no
   slash-command injection.

This is the cleanest delivery path for OpenCode: messages travel broker-native
until the plugin drains them and injects them through the official plugin API.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Claude Code | No | Claude Code does not have an equivalent plugin `promptAsync` API. |
| Codex | No | Codex does not have a plugin system with `promptAsync`. |
| Pi Agent | No | Pi Agent has its own extension API. |
| OpenCode | Yes | Preferred delivery mechanism. Proven 2026-04-14. |
| Kimi | No | Kimi does not have an equivalent plugin `promptAsync` API. |

#### Key files

| File | Role |
|------|------|
| `ocaml/cli/c2c_setup.ml` | Setup logic invoked by `c2c install opencode`; writes `.opencode/opencode.json`, the `.opencode/c2c-plugin.json` sidecar, and installs the plugin |
| `.opencode/plugins/c2c.ts` | The TypeScript plugin itself (dev symlink to `data/opencode-plugin/c2c.ts`, or embedded blob in binary-only installs) |

#### Limitations

- OpenCode-specific: no other client has an equivalent plugin API.
- Requires `npm install` in the `.opencode/` directory after setup.
- Background polling at 2-second intervals adds slight latency vs.
  event-driven delivery.
- Plugin must be installed per-project.

---

### 9. Kimi REST Prompt Injection

**REST prompt POST to the Kimi Code local server** -- The canonical delivery
path for managed Kimi sessions, replacing the deprecated wire-bridge path (and
the legacy file-based notification-store, which Kimi Code no longer reads).

#### How it works

`c2c start kimi` forks a **kimi-notifier daemon** (`C2c_kimi_notifier`)
alongside the kimi TUI process. The notifier:

1. Polls the c2c broker inbox every 2 seconds.
2. Drains messages for the Kimi alias.
3. Discovers the active Kimi Code session id (`session_<uuid>`, minted by Kimi
   Code itself) from `~/.kimi-code/session_index.jsonl`.
4. Ensures the local Kimi server (`kimi server run`) is listening.
5. POSTs each message as a user prompt to
   `http://127.0.0.1:<port>/api/v1/sessions/{id}/prompts` (bearer token from
   `~/.kimi-code/server.token`). The prompt body is the canonical c2c XML
   envelope `<c2c event="message" from="..." to="...">...</c2c>` — data-only,
   never an approval (B098).
6. Optionally sends a tmux `send-keys` wake-prompt when the kimi pane appears idle.

Managed `c2c start kimi` (or `c2c new kimi` for a fresh session) launches
Kimi Code without `--session` (Kimi Code 0.23+ does not resume arbitrary
passed ids). For unmanaged or serverless
setups, `c2c monitor` (e.g. under a Monitor) is the fallback. A SessionStart
hook (`c2c hook kimi`) auto-registers the session with the broker.

#### Client support

| Client | Supported | Notes |
|--------|-----------|-------|
| Kimi | **Yes — Primary** | REST prompt POST to the local Kimi Code server. Replaces wire-bridge; legacy notification-store deprecated. |
| Claude Code | No | — |
| Codex | No | — |
| Pi Agent | No | Uses `pi-c2c` extension delivery instead. |
| OpenCode | No | — |
| Grok | No | — |

#### Key files

| File | Role |
|------|------|
| `ocaml/c2c_kimi_notifier.ml` / `.mli` | Notifier daemon implementation |
| `ocaml/c2c_kimi_deliver.ml` / `.mli` | REST server discovery + prompt POST (`submit_prompt`) |
| `ocaml/c2c_start.ml` (`start_kimi_notifier`) | Spawning logic in `run_outer_loop` |
| `deprecated/c2c_kimi_wire_bridge.py` | **Deprecated** wire-bridge (retained for reference) |

#### Limitations

- Requires the local Kimi server (`kimi server run`) to accept the prompt POST;
  the notifier ensures it is running, but serverless setups fall back to
  `c2c monitor`.
- Requires a live Kimi Code session resolvable from
  `~/.kimi-code/session_index.jsonl`.
- tmux send-keys wake-prompt may not fire if pane is in copy-mode.
- Notifier daemon must be running (`c2c start kimi` starts it automatically).

See `.collab/runbooks/kimi-notification-store-delivery.md` (internal,
deprecated) for the legacy file-based mechanism.

---

## Delivery Method Selection by Client

Which methods are primary, fallback, or unavailable for each client:

| Method | Claude Code | Codex | Pi Agent | OpenCode | Kimi | Grok |
|--------|:-----------:|:-----:|:--------:|:--------:|:----:|:----:|
| MCP Channel Notifications | Fallback (gated) | -- | -- | -- | -- | -- |
| PostToolUse Hook | **Primary** | Vanilla **Primary** / managed **Fallback** | -- | -- | -- | -- |
| Codex app-server inject + gated auto-turn | -- | Managed **Primary** (supported ≥0.144) | -- | -- | -- | -- |
| PTY Injection | Deprecated | Legacy sentinel | -- | Fallback | Fallback | -- |
| History.jsonl Injection | Experimental | -- | -- | -- | -- | -- |
| poll_inbox Tool | Baseline | Baseline | CLI baseline | Baseline | Baseline | **Baseline** (CLI) |
| Wake Daemon | Idle bridge | Hook-mode wake inject | **Primary** (`pi-c2c`) | Fallback | Fallback | -- |
| Monitor + `c2c monitor` | Idle awareness | -- | -- | (plugin-internal) | Fallback (unmanaged) | **Primary** |
| Kimi Wire Bridge | -- | -- | -- | -- | Deprecated | -- |
| Kimi REST Prompt Injection | -- | -- | -- | -- | **Primary** | -- |
| OpenCode Native Plugin | -- | -- | -- | **Primary** | -- | -- |

**Primary** = recommended path for that client; for MCP clients this is installed
by `c2c install <client>`, while Pi Agent uses `pi install npm:pi-c2c`. Managed
Codex on a supported binary uses the app-server path (not hooks) as Primary.
**Baseline** = always available as a universal pull-based fallback.
**Fallback** = works but superseded by a better method.
**--** = not applicable or not supported.

**agy (Google Antigravity)** is omitted from the column set above to keep the
table aligned. It mirrors the Grok row — `poll_inbox` / `c2c poll-inbox`
**Baseline** and a **Monitor** on `c2c monitor` — and adds a managed
**agentapi wake** path (`c2c start agy` deliver-watch sidecar,
`c2c_agy_deliver.ml`, via `agy agentapi send-message`) as its **Primary** when
managed. Unlike Grok, managed `c2c start agy` is real (via `AgyAdapter`). No MCP.

---

## Message Flow: End-to-End

Regardless of delivery method, the message lifecycle follows the same
broker-native path:

```
Sender agent
    |
    | mcp__c2c__send (or c2c send CLI)
    v
OCaml broker: enqueue_message
    |
    | Atomic write to <session_id>.inbox.json (lockf + tmp + rename)
    v
Recipient's inbox file
    |
    |  +-- Host hook fires (Claude Code PostToolUse; Codex UserPromptSubmit/PostToolUse)
    |  +-- Codex app-server inject + gated auto-turn (managed supported Codex)
    |  +-- Native plugin + alias-scoped c2c monitor (OpenCode)
    |  +-- REST prompt injection via C2c_kimi_notifier (Kimi)
    |  +-- Monitor on c2c monitor (Grok preferred)
    |  +-- agentapi inject via deliver-watch sidecar (agy, managed c2c start agy)
    |  +-- Wake daemon PTY-injects sentinel (legacy)
    |  +-- Agent manually calls poll_inbox (universal)
    v
poll_inbox drains inbox --> archive --> returns messages
    |
    v
Agent receives <c2c event="message" from="..." to="...">body</c2c>
```

---

## Environment Variables

Key environment variables that control delivery behavior across methods:

| Variable | Default | Set by | Purpose |
|----------|---------|--------|---------|
| `C2C_MCP_BROKER_ROOT` | `$HOME/.c2c/repos/<fp>/broker` | `c2c install` | Broker root directory (shared across worktrees and clones of the same upstream; `<fp>` = SHA-256 of `remote.origin.url`). Resolution: `C2C_MCP_BROKER_ROOT` → `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (if set) → default; generic `XDG_STATE_HOME` is not honored (#9 split-brain fix). See root `CLAUDE.md` "Key Architecture Notes". |
| `C2C_MCP_SESSION_ID` | Auto-discovered | `c2c install` or `c2c start` | Session identifier for inbox resolution |
| `C2C_MCP_AUTO_REGISTER_ALIAS` | Per-client default | `c2c install` | Stable alias across restarts |
| `C2C_MCP_AUTO_JOIN_ROOMS` | `swarm-lounge` | `c2c install` | Comma-separated rooms to auto-join |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | `1` (server default; `c2c install` writes `0`) | `c2c install` | Enable post-initialize channel drain (requires client support) |
| `C2C_MCP_CHANNEL_DELIVERY` | `1` (Claude Code) | `c2c install claude` | Enable continuous inbox watcher for channel notifications |

---

## Related Documentation

- [Architecture](/architecture/) -- Broker design, concurrency, crash safety
- [Per-Client Delivery](/client-delivery/) -- Per-client diagrams and setup
- [Communication Tiers](/communication-tiers/) -- Reliability tiers for all methods
- [Channel Notification Implementation](channel-notification-impl.md) -- Detailed channel notification spec
- Codex Channel Research — `.collab/findings-archive/c2c-research/codex-channel-notification.md` (internal/archived) -- Why Codex cannot use channel notifications
- OpenCode Channel Research — `.collab/findings-archive/c2c-research/opencode-channel-notification.md` (internal/archived) -- Why OpenCode cannot use channel notifications
