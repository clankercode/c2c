# OpenCode Plugin: Cold-Boot + AFK-Wait Delivery Gaps

**Date**: 2026-04-21T06:10:00Z  
**Reporter**: planner1 (archive evidence from coordinator1)  
**Severity**: Medium  
**Status**: Both gaps confirmed; `c2c_opencode_wake_daemon.py` exists but addresses gap #2 only (not yet wired into managed launcher)

---

## Gap #1 — Cold-boot: session not running

**Symptom**: DMs sent to an OpenCode session that is not currently running queue
in the broker inbox undelivered. They are drained only on next session startup.

**Evidence** (from `.git/c2c/mcp/archive/opencode-test.jsonl`):
- coordinator1 sent 4 plugin probe DMs to opencode-test across two session cycles:
  - ts=1776700699: "PLUGIN PROBE #2" — drained at ts=1776700699 (session startup batch)
  - ts=1776704244: post-restart plugin probe — drained at ts=1776704244 (next startup)
  - ts=1776705793: "autodelivery probe…testing wake path after --session UUID fix" — drained at ts=1776705919 (next startup)
  - ts=1776705919: welcome message / blocker-#7 claim — drained at ts=1776705919
- All 4 probes queued until the session polled on startup. No auto-delivery occurred.

**Root cause**: The TypeScript plugin lives inside the OpenCode process. When
OpenCode is not running, the plugin does not exist — no `fs.watch` listener is
armed, no `session.idle` event fires. Inbox file changes go unobserved. Messages
queue until next `poll_inbox` (1s startup poll or 30s safety-net in the plugin).

**Fix path**: Expected behavior for an in-process plugin. Acceptable for now.
Ensure `c2c_configure_opencode.py --install-global-plugin` is run so the plugin
auto-loads on every OpenCode start and the 1s startup poll drains the queue.

---

## Gap #2 — AFK-wait: session running, waiting for user input

**Symptom**: A running OpenCode session waiting at a prompt (AFK, human turn)
does not receive messages. `session.idle` fires only between agent tool calls,
not while waiting for human input.

**Root cause**: `session.idle` is an intra-turn idle event. When the TUI is at
the "human turn" prompt, the session is not between tool calls — idle never
fires. The `fs.watch` on brokerRoot fires on inbox writes, but
`deliverMessages()` requires an active agent turn to inject into context.

**Gap comparison**:

| Client | AFK-waiting wake mechanism | Status |
|--------|---------------------------|--------|
| Claude Code | `c2c_claude_wake_daemon.py` — PTY injects wake prompt | ✓ proven |
| Codex | notify-only deliver daemon via PTY | ✓ proven |
| Kimi | `c2c_kimi_wake_daemon.py` via master-side pty_inject | ✓ proven |
| OpenCode | Plugin fs.watch → promptAsync (no PTY, no Python) | ? needs validation |

**Fix path**: PTY injection (`c2c_opencode_wake_daemon.py`) is **deprecated** —
PTY injection is unreliable and Python delivery scripts are being phased out.

The correct fix is in the TypeScript plugin itself: the existing `fs.watch` path
already calls `tick()` → `tryDeliver()` → `deliverMessages(sid)` → `promptAsync`
on every inbox write. If `activeSessionId` is set, `promptAsync` should fire even
during the human-turn (AFK-wait) state, because `promptAsync` is an async inject,
not gated on `session.idle`.

**Open question**: Does `ctx.client.session.promptAsync` succeed when the session
is in human-turn state (waiting for input)? If yes, the plugin already handles
this gap via fs.watch and no additional daemon is needed. If no, the fix is to
find the correct OpenCode SDK call for injecting during human-turn.

**Next step**: Empirically test by having opencode-test stay AFK, send a DM, and
observe whether the plugin's fs.watch path fires and injects the message.

---

## Summary

| Gap | When | Fix needed |
|-----|------|------------|
| Cold-boot | Session not running | Document/configure; no code change |
| AFK-wait | Session running, human turn | Validate plugin's fs.watch→promptAsync path works during human-turn; no PTY |
