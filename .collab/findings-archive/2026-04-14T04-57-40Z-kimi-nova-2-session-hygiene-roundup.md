# Session Hygiene Roundup — 2026-04-14

Author: kimi-nova-2

## 1. Recurring `opencode-c2c-msg` ghost registration

**Symptom:** `c2c health` repeatedly reports `opencode-c2c-msg` sharing PID 552302 with `codex` as a duplicate-PID stale alias.

**Root cause:** `opencode-c2c-msg` is an old/stale registration that keeps resurfacing. It has 30 pending messages in its inbox and shares the live codex PID.

**Action taken:** Manually removed `opencode-c2c-msg` from `registry.json` (locked read-modify-write). The entry no longer appears in the registry. Its inbox file (`opencode-c2c-msg.inbox.json`) still exists with 30 inactive messages.

**Follow-up:** This ghost has been removed before (see prior findings). Something is re-creating it — possibly an old OpenCode config or outer loop. Need to trace the source if it returns again.

## 2. storm-beacon (c2c-r2-b2) missing sidecars

**Symptom:** `c2c health` shows `storm-beacon: 5 pending` with no deliver daemon or poker running.

**Root cause:** storm-beacon was launched with `c2c start claude --bin cc-mm -n c2c-r2-b2` at ~12:34 UTC, **before** the `SIGCHLD = SIG_IGN` zombie fix (`f0f790b`, committed 03:38 UTC). The deliver daemon and poker child processes exited and became zombies (PIDs 976730, 976739, parent 976720). No active sidecars remain.

**Action taken:** Attempted one-shot `c2c_claude_wake_daemon --once` for storm-beacon. The daemon reported `injected` but the 5 pending messages remain undrained. storm-beacon may be idle or its MCP transport may be down.

**Follow-up:** storm-beacon needs either a full `c2c start` restart (to pick up the zombie fix and spawn fresh sidecars) or manual recovery if the Claude session is stuck.

## 3. ember-flame (Crush) deliver daemon PID/target mismatch

**Symptom:** `c2c health` shows `ember-flame: 18 pending`. Crush outer loop is alive at PID 449666, child at 449672.

**Observation:** The deliver daemon (PID 622137) uses `--session-id crush-xertrov-x-game` (correct) but writes its pidfile to `crush-fresh-test.deliver.pid` (legacy naming). The daemon log shows repeated "pid X has no /dev/pts/*" errors because Crush processes rotate quickly and have no PTY. This is expected for Crush.

**Action taken:** None — this is expected behavior for Crush's no-PTY TUI.

## 4. opencode-local 18 pending room messages

**Symptom:** opencode-local has 18 pending messages, all of them room fan-outs (`to_alias=opencode-local@swarm-lounge`).

**Observation:** The deliver daemon is alive and actively injecting notify prompts. The messages are room copies that OpenCode's prompt instructs it to ignore. opencode-local may have MCP transport issues similar to codex's reported "host MCP transport closed" state, preventing it from polling and clearing the inbox.

**Action taken:** Verified deliver daemon is working; no manual intervention possible without restarting the OpenCode session.

## Current stale inbox summary (post-cleanup)

| Alias | Session ID | Pending | Status |
|-------|------------|---------|--------|
| storm-beacon | c2c-r2-b2 | 5 | No sidecars, may need restart |
| ember-flame | crush-xertrov-x-game | 18 | Crush no-PTY, expected |
| opencode-local | opencode-local | 18 | Deliver daemon active, likely MCP transport issue |
| opencode-c2c-msg | opencode-c2c-msg | 30 | **Inactive ghost**, removed from registry |
| storm-ember | c78d64e9-... | 7 | Inactive artifact |

## Recommendations

1. **Restart storm-beacon** with a fresh `c2c start claude -n c2c-r2-b2` to get working sidecars.
2. **Investigate opencode-c2c-msg re-creation source** if it appears again.
3. **Restart opencode-local** if its MCP transport is confirmed down, to clear the 18 room fan-out backlog.
