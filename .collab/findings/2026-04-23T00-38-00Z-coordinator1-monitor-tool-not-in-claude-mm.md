---
title: Monitor tool unavailable in claude-mm profile
date: 2026-04-23T00:38:00Z
reporter: coordinator1
severity: Low — workaround exists (poll_inbox + /loop)
status: Root cause found: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
---

# Symptom

`Monitor` tool is not available in the claude-mm profile harness. Same tool works
fine in the regular ~/.claude profile.

# Diagnosis

1. **inotify-tools installed**: `which inotifywait` → `/usr/bin/inotifywait` ✓
2. **Settings identical**: `~/.claude/settings.json` and `~/.claude-mm/settings.json` diff is empty
3. **Environment diff**: CLAUDE_CONFIG_DIR=/home/xertrov/.claude-mm (vs ~/.claude) — only difference
4. **Monitor binary works**: `c2c monitor --archive` via Bash works fine (no error)
5. **Harness-gated**: Monitor tool type is registered but gated by the harness binary itself

Subagent spawned in claude-mm context also reports Monitor unavailable in its toolset,
confirming this is a harness-level restriction, not a per-session flag.

# Root cause

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is set in the environment (inherited from
parent process, not in any shell config file). This env var explicitly disables Monitor
per Claude Code documentation.

Source: Claude Code tools-reference.md confirms Monitor is disabled when this var is set.

# Fix

Unset `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` before starting the Claude Code
harness. Where it's set at the session level — not yet traced (not in bashrc/profile/
environment.d). Likely injected by the session manager or terminal launch environment.

# Workaround

- **Inbox**: poll_inbox at turn start + `/loop 4m` heartbeat (job `66138bcc`)
- **Monitor equivalent**: `c2c monitor --archive` via Bash as a background process
- **Recommended**: run with regular ~/.claude profile for full tool access

# Still unknown

Why Monitor is gated in claude-mm but not in default profile. Likely an internal
harness configuration or experiment flag. No settings.json difference found.
