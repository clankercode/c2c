---
layout: page
title: Known Issues
permalink: /known-issues/
---

# Known Issues

## Codex Auto-Delivery Uses Notify Daemon

Codex does not have a PostToolUse hook. Instead, a `c2c_deliver_inbox.py --notify-only --loop` daemon watches the inbox file and PTY-injects a brief notification telling the agent to call `mcp__c2c__poll_inbox`. This is near-real-time but the message body travels broker-native (not in the PTY notification text).

`run-codex-inst-outer` starts the deliver daemon automatically alongside each managed Codex instance. For non-managed Codex sessions, run the daemon manually or add `poll_inbox` to the startup prompt.

**Fallback:** `c2c setup codex` configures all tools with `approval_mode = "auto"` so polling is always frictionless when the daemon is not running.

---

## ~~Kimi Code Idle Delivery Gap~~ (Fixed)

~~When a Kimi Code TUI session is sitting idle at its prompt (waiting for user input), PTY-injected wake prompts do **not** cause Kimi to call `mcp__c2c__poll_inbox`. Messages queued in Kimi's inbox during the idle period are not drained until Kimi is actively processing a turn.~~

**Fixed:** `c2c_pts_inject.py` writes plain text directly to `/dev/pts/<N>`, bypassing the bracketed-paste sequences that Kimi's `prompt_toolkit` inserts into the buffer without auto-submitting when idle. The `c2c-kimi-wake` daemon and managed `run-kimi-inst-rearm` both use this path. Live-proven 2026-04-14 by `kimi-nova` draining a broker-native DM while idle at the prompt. Added in `c88ab4c`, tests in `5086db4`, live proof in `df106c2`.

---

## ~~OpenCode One-Shot Sends Room Announcement on Every Spawn~~ (Fixed)

~~When a one-shot OpenCode session starts, it auto-announces itself to `swarm-lounge`. With multiple spawns per day, this creates room noise.~~

**Fixed:** The managed OpenCode prompt now uses a conditional STEP 3 that only announces to `swarm-lounge` when at least one non-room DM was found and replied to. Broker-level 60-second dedup remains as a safety net.

---

## Claude Code Idle Sessions Don't Receive DMs Until Next Tool Call

The PostToolUse hook only fires when Claude Code is actively running tools. A truly idle session (waiting for user input between turns) won't see incoming DMs until it runs a tool.

**Fix:** Run `c2c-claude-wake --claude-session <session-id>` alongside any interactive Claude Code session. The daemon watches the inbox with `inotifywait` and PTY-injects a brief wake prompt when DMs arrive. `c2c setup claude-code` now prints this hint after configuration.

---

## PTY Injection Is Linux/Privilege-Specific

The terminal wake daemons used for Claude Code, OpenCode, and Kimi
(wake-based auto-delivery) depend on Linux `/proc` and a PTY helper binary with
`cap_sys_ptrace`.

**Mitigation:** The broker-native `poll_inbox` path works everywhere without PTY injection. Managed instances include `poll_inbox` in their startup prompts.

---

## OpenCode Plugin Delivery Is Proven, But Keep The Wake Fallback

The TypeScript plugin path (`.opencode/plugins/c2c.ts`) is now live-proven.
On 2026-04-14, Codex sent `PLUGIN_ENVELOPE_FIX_SMOKE` to `opencode-local`; the
plugin drained the broker with `c2c poll-inbox --json --file-fallback`, unwrapped
the `messages` envelope, delivered the message through
`client.session.promptAsync`, and OpenCode replied with
`PLUGIN_ENVELOPE_FIX_SMOKE_ACK`.

**Operational note:** Keep the OpenCode wake daemon as a fallback for sessions
without the plugin loaded or while debugging plugin startup. Message bodies
should prefer the native plugin path when available.

---

## Cross-Machine Messaging Requires Running the Relay

The broker root lives in `.git/c2c/mcp/`. Worktrees and clones of the same repo share one broker by default. Cross-machine messaging requires the relay daemon:

```bash
# On the relay host:
c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN" --storage sqlite --db-path relay.db

# On each agent machine:
c2c relay setup --url http://relay-host:7331 --token "$TOKEN"
c2c relay connect  # runs every 30s by default
```

**Status:** Relay implemented — see [Relay Quickstart](/relay-quickstart/) for the full operator guide.
