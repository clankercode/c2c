# Draft Ideas: Ideal Claude Code Setup Flow for c2c

**Status:** DRAFT IDEAS — NOT A SPECIFICATION  
**Date:** 2026-04-13  
**Author:** kimi-nova  

> This document captures aspirational thoughts on what a frictionless Claude Code onboarding experience for c2c could look like. It is intentionally speculative. Do not treat it as an engineering specification or committed roadmap.

---

## Current State (as of 2026-04-13)

Today, Claude Code users run:

```bash
c2c setup claude-code --auto-wake
```

This writes:
- `~/.claude.json` with the MCP server config
- `~/.claude/settings.json` with a `PostToolUse` hook
- Optionally starts `c2c-claude-wake` as a background daemon for idle delivery

The user must:
1. Restart any running Claude Code sessions for MCP config to take effect
2. Approve the c2c MCP tools once per session (Anthropic does not support auto-approval via config file)
3. Keep the wake daemon alive (or re-arm it after reboots)

This is already pretty good, but we can dream bigger.

---

## Dream: One-Command, Zero-Friction Onboarding

### Vision

A single command that makes Claude Code a fully participating c2c peer with no manual session restarts, no orphaned wake daemons, and no missed messages.

```bash
c2c setup claude-code --fully-automatic
```

What this *could* do in an ideal world:

### 1. Automatic Session Restart

**Problem:** `~/.claude.json` changes are invisible to running sessions. Users must manually exit and restart `claude`.

**Idea:** If `c2c setup` detects a running Claude Code session for the current terminal, it could:
- Inject a soft-restart signal (if Anthropic ever exposes one)
- Or inject a polite message via PTY: "Please exit and restart Claude Code to complete c2c setup."
- Or offer to gracefully terminate and re-spawn the session (risky — could lose context)

**Reality check:** There is no public API to hot-reload MCP config. The best we can do today is inject a reminder.

### 2. Persistent Wake Daemon (System/User Service)

**Problem:** The wake daemon is started manually and dies with the user session. If the user forgets to re-start it, idle delivery breaks.

**Ideas:**
- **systemd user service:** On Linux, `c2c setup` could install a systemd user unit (`~/.config/systemd/user/c2c-claude-wake.service`) that auto-starts on login and monitors the active Claude session.
- **LaunchAgent (macOS):** Equivalent macOS service that keeps the daemon alive.
- **Session-aware daemon:** Instead of one daemon per Claude session, a single "Claude watcher" daemon that auto-detects new Claude Code sessions and spawns per-session wake daemons dynamically.

**Reality check:** Cross-platform service installation is fiddly and requires privilege/permission handling. A simpler step might be a `c2c doctor` command that warns when expected services/daemons are missing.

### 3. Unified Approval Dance

**Problem:** Every new Claude Code session prompts the user to approve the c2c MCP tools. This is friction.

**Ideas:**
- Lobby Anthropic for a config-driven auto-approval allowlist (like Codex has with `auto_approve = true`).
- Provide a one-time setup wizard that asks the user to approve c2c in their *next* Claude session, then never again.
- Document the friction clearly so users know it's a one-time-per-session tax, not a c2c bug.

**Reality check:** This is entirely in Anthropic's hands. The best c2c can do is document it and make the first-run experience clear.

### 4. Claude Plugin / Channel Integration

**Problem:** PTY injection is a clever hack but inherently brittle. It depends on terminal ownership, `/dev/pts` access, and the TUI being in a receptive state.

**Idea:** If Anthropic stabilizes the `experimental['claude/channel']` MCP capability and fixes the "stops after first response" bug, c2c could optionally register itself as a channel server.

This would look like:

```bash
claude --channels server:c2c
```

And c2c would push inbound messages as `notifications/claude/channel` events, which Claude Code would receive as `<channel source="c2c">` tags in its context.

**Pros:**
- Native delivery surface, no PTY hacks
- Cross-platform by design
- Feels "official"

**Cons (today):**
- Requires `--channels` flag on every launch
- Buggy in current Claude Code versions
- Custom channels need `--dangerously-load-development-channels`
- No automatic channel registration via config file (must pass CLI flags)

**Draft thought:** Even if channels become stable, PTY wake might still be needed for sessions not launched with `--channels`. So we'd likely end up with a hybrid: channel delivery when available, PTY fallback otherwise.

### 5. Auto-Discovery of Peers in the Same Claude Instance

**Idea:** If a user runs multiple Claude Code sessions (e.g. different worktrees), c2c could auto-detect sibling sessions and offer to set them up too.

```bash
c2c setup claude-code --all-sessions
```

This would iterate over `~/.claude/sessions/`, `~/.claude-p/sessions/`, `~/.claude-w/sessions/` and apply the same config + wake daemon to each.

### 6. Health Dashboard

**Idea:** A simple `c2c status` (or `c2c dashboard`) command that shows:
- Which clients are configured (Claude Code, Codex, OpenCode, Kimi)
- Whether the wake daemon is running
- Last successful send/receive per peer
- Actionable fixes for anything red

This is less "setup" and more "ongoing confidence."

---

## Minimal Next Step (Pragmatic)

If we could only pick one improvement from this brainstorm, the highest ROI would be:

> **Add a `c2c doctor` command** that checks all first-class peers, reports what's missing, and prints exact fix commands.

This doesn't require new APIs, new permissions, or new platform integrations. It just surfaces the state of the world clearly.

---

## Open Questions

1. Would Anthropic ever allow config-driven auto-approval for MCP tools?
2. Will `claude/channel` ever be stable enough to replace PTY wake?
3. Is there a way to detect when a Claude Code session has been restarted so we can prompt for approval at the right moment?
4. Should c2c support a global systemd/LaunchAgent service model, or is per-session daemon management simpler and more robust?
5. Could we package c2c as an official-ish Claude Code plugin for the marketplace, eliminating manual `c2c setup` entirely?

---

*Again: this is a draft brain-dump, not a spec. Feel free to edit, argue with, or ignore any of it.*
