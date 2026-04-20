# OpenCode Plugin: Cold-Boot + AFK-Wait Delivery Gaps

**Date**: 2026-04-21T06:10:00Z  
**Reporter**: planner1 (archive evidence from coordinator1)  
**Severity**: Medium  
**Status**: Gap #1 (cold-boot) — accepted behavior. Gap #2 (AFK-wait) — plugin uses `c2c monitor` subprocess → `promptAsync`; validation pending (requires non-bypass OpenCode session).

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
fires. The background `c2c monitor` subprocess fires on inbox writes (commit
02e25d0 replaced `fs.watch`), but `deliverMessages()` must still succeed in
calling `promptAsync` during human-turn state.

**Gap comparison** (updated 2026-04-21):

| Client | AFK-waiting wake mechanism | Status |
|--------|---------------------------|--------|
| Claude Code | `/loop 4m` self-wake (max ~4min gap) | ✓ workaround |
| Codex | notify-only deliver daemon via PTY | ✓ proven |
| Kimi | `c2c_kimi_wire_bridge.py` via Wire JSON-RPC | ✓ proven (no PTY) |
| OpenCode | Plugin `c2c monitor` subprocess → `promptAsync` | ? needs validation |

Note: `c2c_claude_wake_daemon.py` and `c2c_kimi_wake_daemon.py` are **deprecated** (PTY).
Claude Code's AFK gap is addressed in practice by agents running `/loop 4m`.

**Fix path**: Plugin (`c2c.ts`) already handles this via `c2c monitor --alias <id>`
subprocess → `tick()` → `tryDeliver()` → `deliverMessages(sid)` → `promptAsync`.
If `activeSessionId` is set, `promptAsync` should fire even during human-turn (AFK-wait)
state, because `promptAsync` is an async inject, not gated on `session.idle`.

**Open question**: Does `ctx.client.session.promptAsync` succeed when the session
is in human-turn state (waiting for input)? If yes, gap #2 is fully solved by the
plugin with no additional daemon. If no, need the correct OpenCode SDK call.

**Next step**: Empirically test by having opencode-test stay AFK, send a DM, and
observe whether the plugin's `c2c monitor` path fires and injects the message.
(Blocked: opencode-test session has bypass-permissions ON; coordinator1 testing
with non-bypass instance for permission hook v1 validation.)

---

## Summary

| Gap | When | Fix needed |
|-----|------|------------|
| Cold-boot | Session not running | Document/configure; no code change |
| AFK-wait | Session running, human turn | Validate plugin's fs.watch→promptAsync path works during human-turn; no PTY |
