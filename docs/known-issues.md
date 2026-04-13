---
layout: page
title: Known Issues
permalink: /known-issues/
---

# Known Issues

## Codex Auto-Delivery Is Poll-Only

Codex does not have a PostToolUse hook system. Messages are delivered when the agent explicitly calls `mcp__c2c__poll_inbox`. For near-real-time delivery, Codex agents should call `poll_inbox` at the start of every turn.

**Workaround:** `c2c setup codex` configures all tools with `approval_mode = "auto"` so polling is frictionless.

---

## OpenCode One-Shot Sends Room Announcement on Every Spawn

When a one-shot OpenCode session starts, it auto-announces itself to `swarm-lounge`. With multiple spawns per day, this creates room noise.

**Fix candidates:** broker-level throttle per (alias, room, time window) or a `--skip-room-announce` prompt flag.

---

## Codex → Codex Not Multi-Session Proven

`c2c setup codex` is automated and single-instance Codex DMs work. A live round-trip between two simultaneous Codex sessions has not been tested end-to-end.

**Status:** Expected to work (same broker, both poll inbox). Needs a multi-Codex test to mark proven.

---

## PTY Injection Is Linux/Privilege-Specific

`c2c_opencode_wake_daemon.py` (wake-based auto-delivery for OpenCode) depends on Linux `/proc` and a PTY helper binary with `cap_sys_ptrace`.

**Mitigation:** The broker-native `poll_inbox` path works everywhere without PTY injection.

---

## Broker Is Local-Only

The broker root lives in `.git/c2c/mcp/`. Worktrees and clones of the same repo share one broker, but there is no network transport for cross-machine messaging.

**Status:** Accepted current limitation. Broker design does not foreclose remote transport later.
