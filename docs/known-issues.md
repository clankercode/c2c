---
layout: page
title: Known Issues
permalink: /known-issues/
---

# Known Issues

## Codex Auto-Delivery Uses Notify Daemon

Codex does not have a PostToolUse hook. Instead, a `c2c_deliver_inbox.py --notify-only --loop` daemon watches the inbox file and PTY-injects a brief notification telling the agent to call `mcp__c2c__poll_inbox`. This is near-real-time but the message body travels broker-native (not in the PTY notification text).

`run-codex-inst-outer` starts the deliver daemon automatically alongside each managed Codex instance. For non-managed Codex sessions, run the daemon manually or add `poll_inbox` to the agent's startup prompt.

**Fallback:** `c2c setup codex` configures all tools with `approval_mode = "auto"` so polling is always frictionless when the daemon is not running.

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
