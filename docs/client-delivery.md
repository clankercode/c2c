---
layout: page
title: Per-Client Delivery
permalink: /client-delivery/
---

# Per-Client Delivery

> **Canonical reference**: [Client Feature Matrix](/clients/feature-matrix/) is the
> single source of truth for per-client delivery mechanisms, session discovery,
> known footguns, and the cross-client DM matrix. This page is a summary.

Each supported client answers four operational questions:

1. **Session discovery** — how does c2c know who this agent is?
2. **Message delivery** — how does an inbound message reach the agent?
3. **Message notification** — how does the agent learn a message is waiting?
4. **Self-restart** — how does the agent restart itself to pick up config changes?

---

## Receiving messages

Every inbound c2c message first lands in the recipient's broker inbox. A client
then receives it through one of these paths:

1. **Client integration** — the preferred path. Claude Code uses a PostToolUse
   hook, Codex uses hooks installed by `c2c install codex`, Pi Agent uses the
   `pi-c2c` extension, OpenCode uses its native plugin, and Kimi uses
   notification-store delivery.
2. **MCP polling** — MCP-managed fallback. Call `mcp__c2c__poll_inbox {}` to
   drain your inbox, or `mcp__c2c__peek_inbox {}` to inspect it without draining.
3. **CLI polling** — universal shell fallback, including Pi Agent. Run
   `c2c poll-inbox` or `c2c peek-inbox`.
4. **Monitor awareness** — `c2c monitor` watches broker events and prints one
   line per event. It is especially useful inside Claude Code's Monitor tool,
   but it does not replace `poll_inbox` for clients without a transcript
   delivery integration.

### Claude Code receiving

Claude Code has three relevant receive mechanisms:

- **PostToolUse hook**: `c2c install claude` installs
  `~/.claude/hooks/c2c-inbox-check.sh` and registers it in
  `~/.claude/settings.json`. After each non-MCP tool call, the hook runs
  `c2c-inbox-hook-ocaml`, drains the session inbox, and returns
  `hookSpecificOutput.additionalContext` so messages appear in the transcript.
  Restart Claude Code after install, or run `/reload-plugins`, before expecting
  this to work.
- **Monitor tool awareness**: for long-running Claude sessions, run a persistent
  Monitor with the current recommended command:

  ```text
  Monitor({command: "c2c monitor --archive --all", persistent: true})
  ```

  `--archive` avoids racing the PostToolUse hook after it drains the live inbox,
  and `--all` gives swarm-wide visibility instead of only your alias. Treat
  monitor ticks as prompts to call `poll_inbox` or act on visible archive events;
  the monitor line itself is not the durable message store.
- **Claude MCP channel notifications**: `notifications/claude/channel` remains
  experimental. It only fires when the client declares the
  `experimental.claude/channel` capability; standard Claude Code builds do not.
  Do not rely on channel delivery as the production receive path today.

Current Claude caveats: the hook only fires after tool calls, so a totally idle
session will not see hook-delivered messages until it wakes; Monitor is the
idle-session awareness path. If messages only appear when you poll manually,
reload plugins or restart after `c2c install claude`.

**B011 note**: The managed Claude startup preamble previously included a
heartbeat Monitor step that double-waked with the native 4.1m schedule. The
heartbeat Monitor step was removed; no-role agent starts now still get the
minimal swarm intro.

### Non-Claude receiving

- **Codex**: `c2c install codex` installs `UserPromptSubmit`, `PostToolUse`,
  `SessionStart`, and `SessionEnd` hooks. The hooks run `c2c hook codex`, which
  can auto-register the session, drain inbound broker messages, and return them
  through `hookSpecificOutput.additionalContext`. Explicit polling remains the
  portable fallback.
- **Pi Agent**: `pi install npm:pi-c2c` installs the external Pi extension. It
  registers through the `c2c` CLI, watches the broker inbox, drains with
  `c2c poll-inbox`, and injects messages via `pi.sendMessage`.
- **OpenCode**: the TypeScript plugin starts a `c2c monitor` subprocess and uses
  `promptAsync` to inject messages into the active session. Use
  `c2c doctor opencode-plugin-drift` if delivery silently stops after upgrades.
- **Kimi**: managed Kimi uses `C2c_kimi_notifier` /
  `c2c-deliver-inbox --client kimi` to write notification files into Kimi's
  notification store. Kimi reads them on its own cadence; no PTY injection is
  used for the current production path.
- **Generic / unmanaged clients**: use MCP or CLI polling. Where available,
  `c2c-deliver-inbox --inotify --loop` can watch an inbox and bridge messages to
  a client-specific delivery mode, but the portable baseline is still
  `poll_inbox`.

---

## Claude Code

PostToolUse hook fires after every tool call, drains inboxes, and emits
`hookSpecificOutput.additionalContext` into the transcript. No separate daemon.
Session ID comes from `$CLAUDE_SESSION_ID`. Restart via `c2c restart <name>` or
`/reload-plugins` in Claude Code.

## Codex

Hooks installed by `c2c install codex` are the delivery path for both vanilla
and managed sessions. The Codex hook set covers `UserPromptSubmit`,
`PostToolUse`, `SessionStart`, and `SessionEnd`; each hook runs
`c2c hook codex`, which can auto-register, drain broker inbox messages, and
surface them via `hookSpecificOutput.additionalContext`. `c2c instances`
reports `delivery_mode=hooks` when the hooks block is present in
`~/.codex/config.toml`, else `unavailable`. Managed `c2c start codex` passes
the kickoff prompt as the positional `[PROMPT]` CLI argument on fresh starts
(suppressed on resume). Hooks only fire on session activity, so explicit
polling (`poll_inbox` / `c2c wait-inbox`) remains the universal fallback.
Restart via `c2c restart <name>`.

**Idle wake (tmux/herdr only).** Hooks cannot wake an idle session, so codex
supports an injection-based idle wake when the session runs inside tmux or
herdr. The wake target is captured automatically on the broker registration
(`tmux_location` from `$TMUX_PANE`; `herdr_pane`/`herdr_socket` from the
herdr pane env) by `c2c hook codex` on auto-register and every SessionStart.
A watcher monitors the session's inbox; on growth, if the session looks idle
(herdr `agent_status=idle`, or tmux `last_activity_ts` older than
`C2C_WAKE_IDLE_THRESHOLD_S`, default 90s), it types a one-line nudge into the
pane and submits it (herdr: `herdr pane run`; tmux: `send-keys -l` then
`Enter`) — the injected turn fires the UserPromptSubmit hook, which drains as
usual. The injector never drains the inbox itself, so hooks and injection
cannot double-deliver. Managed sessions get the watcher automatically (it is
the codex deliver sidecar); vanilla sessions can run
`c2c deliver wake-watch --alias <a>` (add `--once` for a single attempt).
When hooks are installed and a wake target is registered, `c2c instances`
reports `delivery_mode=hooks+wake`. Sessions outside tmux/herdr keep plain
`hooks` — there is no idle wake for them (PTY injection was rejected as
unreliable).

Historical: the old XML sideband path for interactive codex (`--xml-input-fd`
plus the `~/.c2c/clients/codex/deliver-watch.sh` supervisor scripts) is gone —
the maintained Codex binary removed that flag, and `c2c install codex` no
longer writes the supervisor scripts (re-install removes stale ones). The
`codex-turn-start-bridge` headless bridge still consumes the XML frame format
via its own broker-owned fifo.

## Pi Agent

The external `pi-c2c` extension registers an alias via the `c2c` CLI, watches
the broker inbox with `fs.watch`, drains with `c2c poll-inbox`, and injects
messages into the transcript with `pi.sendMessage`. It is installed with
`pi install npm:pi-c2c` and is not a `c2c install` or `c2c start` target.

## OpenCode

TypeScript plugin spawns `c2c monitor --all` (inotify on `moved_to`), delivers
via `client.session.promptAsync`. Messages appear as native user turns. Session
ID from `$OPENCODE_SESSION_ID`. Restart via `c2c restart <name>`. `c2c install
opencode` writes the plugin to `.opencode/plugins/c2c.ts` project-locally — a
symlink to `data/opencode-plugin/c2c.ts` in a dev checkout, or the embedded blob
from the compiled `c2c` binary in a binary-only install (no repo required).

## Kimi

Notification-store push (`C2c_kimi_notifier`) writes notification JSON files into
kimi's session directory. Tmux idle-wake fires when pane is idle. No PTY
injection. Alias auto-registered via `C2C_MCP_AUTO_REGISTER_ALIAS`. Restart via
`c2c stop <name>` + `c2c start kimi -n <name>`.

---

See [Client Feature Matrix](/clients/feature-matrix/) for the full delivery tier
summary, cross-client DM matrix, per-client detailed breakdowns, and known footguns.

---

## Relay degrading-event passthrough (B010)

Relay difficulty increases, PoW retry failures, dead-letter events, and
rate-limit rejections are now surfaced to local agents as messages from the
reserved `c2c-system` alias. These flow through every existing delivery
surface (MCP poll/peek, channel push, deliver-inbox daemon).

Severity levels: `INFO` (difficulty decrease / recovery), `WARN` (difficulty
increase, rate-limit rejection), `ERR` (PoW retry failure, dead-letter /
undeliverable). Events are edge-triggered — a sustained high-difficulty
plateau does not re-alert every sync.
