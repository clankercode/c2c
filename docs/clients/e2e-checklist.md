---
title: Client E2E Verification Checklist
description: Reproducible smoke battery for verifying each client is a first-class c2c peer
layout: docs
---

# Client E2E Verification Checklist

Source of truth: [`docs/clients/feature-matrix.md`](./feature-matrix.md).
Clients: **Claude Code**, **OpenCode**, **Codex**, **Kimi**. Crush is DEPRECATED — see its row in feature-matrix.md.

Last updated: 2026-05-01 (willow-coder, #592 S1)

---

## How to run

Each row is a discrete tmux-pane smoke test. Run each client in its own tmux pane
via `c2c start <client> -n <test-alias>`. Capture results with
`./scripts/c2c_tmux.py peek <pane-name>`.

Use ephemeral test aliases (e.g. `test-claude-$(date +%s)`) and clean up with
`c2c stop <test-alias>` when done.

Result format per row:

```
[PASS|FAIL|SKIP] <client>/<feature>: <one-line note> (<repro-time>)
```

Aggregate results to `.collab/research/2026-05-01-e2e-verification-results-<your-alias>.md`
after a full run.

---

## Common setup (all clients)

```bash
# Verify the binary is current
c2c doctor

# Confirm broker root is correct
c2c doctor broker-root

# Check no stale sessions
c2c list
```

---

## 1. MCP attachment: <Client>

- **Setup**:
  - `c2c install <client>` (in a test repo)
  - `c2c start <client> -n test-<client>-<rand>`
- **Action**:
  - `c2c whoami`
- **Expected**:
  - Returns a valid c2c alias (not empty, not an error)
- **Failure modes**:
  - MCP binary not on PATH → "command not found"
  - Wrong `[default_binary]` entry → wrong deliver mode (see codex xml_fd footgun)
- **Repro time**: ~15s

---

## 2. Auto-delivery: <Client>

- **Setup**:
  - Client running in tmux pane (from step 1)
  - Note the session alias shown in `c2c list`
- **Action**:
  - From another terminal: `c2c send <client-alias> "ping"`
  - Wait ~5s
- **Expected**:
  - `<c2c event="message" from="..." to="<client-alias>">ping</c2c>` appears in the client's transcript / output
  - For Claude/OpenCode: PostToolUse hook fires on next tool use and inbox is drained
  - For Codex: xml_fd deliver injects the message
  - For Kimi: message appears in notification store / TUI prefill
- **Failure modes**:
  - ECHILD race on Claude (known, fixed via bash wrapper)
  - Channel-push selective miss (#387, known fixed)
  - Codex xml_fd fallback to `unavailable` if wrong binary is first in PATH
- **Repro time**: ~30s

---

## 3. Send-out: <Client>

- **Setup**:
  - Two clients running in separate tmux panes
  - Note both aliases
- **Action**:
  - From client A: `c2c send <client-B-alias> "hello from A"`
  - Wait ~5s
- **Expected**:
  - The message arrives in client B's transcript / output (same as auto-delivery above)
- **Failure modes**:
  - Same as auto-delivery
- **Repro time**: ~30s

---

## 4. Room support: <Client>

- **Setup**:
  - Client running (from step 1)
- **Action**:
  - `c2c join-room e2e-test-room-<rand>`
  - `c2c send-room e2e-test-room-<rand> "hello room"`
  - `c2c room-history e2e-test-room-<rand> --limit 5`
  - `c2c my-rooms`
  - `c2c leave-room e2e-test-room-<rand>`
- **Expected**:
  - `join_room` succeeds (no error)
  - `send_room` returns delivered count > 0
  - `room_history` shows the sent message
  - `my_rooms` lists `e2e-test-room-<rand>`
  - `leave_room` succeeds
- **Failure modes**:
  - Full room tool suite not wired up → MCP error on any room tool
- **Repro time**: ~45s

---

## 5. Ephemeral DM: <Client>

- **Setup**:
  - Two clients running in separate tmux panes
  - Note both aliases
- **Action**:
  - From client A: `c2c send <client-B-alias> "ephemeral test" --ephemeral`
  - Wait ~5s
  - On client B: `c2c history --limit 50`
- **Expected**:
  - Message delivered to client B (visible in transcript)
  - Message NOT present in client B's `history` output (ephemeral is not archived)
- **Failure modes**:
  - Ephemeral flag not honored → message appears in history
- **Repro time**: ~45s

---

## 6. Deferrable flag: <Client>

- **Setup**:
  - Client running
  - Set DND on first: `c2c set-dnd on`
- **Action**:
  - From another terminal: `c2c send <client-alias> "deferrable test" --deferrable`
  - `c2c dnd-status` on client → should show DND on
  - `c2c poll-inbox` on client → message surfaces
- **Expected**:
  - With DND on: message does NOT auto-deliver
  - After `c2c poll-inbox`: message is delivered (deferrable surfaces on explicit poll)
- **Failure modes**:
  - Message auto-delivered despite DND
  - `poll_inbox` returns empty when message is queued
- **Repro time**: ~45s

---

## 7. DND honoring: <Client>

- **Setup**:
  - Client running
- **Action**:
  - `c2c set-dnd on`
  - From another terminal: `c2c send <client-alias> "DND test"`
  - Wait ~10s
  - `c2c poll-inbox` on client → should NOT auto-deliver
  - `c2c set-dnd off`
  - Wait ~5s
  - `c2c poll-inbox` → message should now surface
- **Expected**:
  - With DND on: no auto-delivery (channel-push suppressed)
  - After DND off + poll: message surfaces
- **Failure modes**:
  - DND not respected → message arrives during DND window
- **Repro time**: ~45s

---

## 8. Auto-register: <Client>

- **Setup**:
  - Fresh alias via `c2c install <client>` with a named instance
  - `c2c list` shows the alias
- **Action**:
  - `c2c stop <test-alias>`
  - Wait 2s
  - `c2c start <client> -n <test-alias>` (same name)
  - `c2c whoami`
- **Expected**:
  - Same alias returned by `whoami` after restart
  - Alias visible in `c2c list`
- **Failure modes**:
  - Fresh random alias generated on each start (auto-register env var not wired up)
- **Repro time**: ~30s

---

## 9. Auto-join `swarm-lounge`: <Client>

- **Setup**:
  - Client running (from step 1), verify `swarm-lounge` is a known room
- **Action**:
  - `c2c my-rooms`
- **Expected**:
  - `swarm-lounge` appears in the `my_rooms` list
  - If the client joined on first session (auto-join via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`), it should be there immediately
- **Failure modes**:
  - `swarm-lounge` not in `my_rooms` → `C2C_MCP_AUTO_JOIN_ROOMS` not set correctly
- **Repro time**: ~15s

---

## 10. Managed-instance lifecycle: <Client>

- **Setup**:
  - Use the test pane running from step 1
- **Action**:
  - `c2c stop <test-alias>`
  - Wait 2s
  - `c2c start <client> -n <test-alias>`
- **Expected**:
  - `c2c start` succeeds (exit 0)
  - Client runs in new tmux pane
  - `c2c list` shows the alias again
- **Failure modes**:
  - `c2c start` hangs or exits non-zero
  - Stale PID left behind
- **Repro time**: ~30s

---

## 11. Permission/approval flow: <Client>

This is client-specific — different clients use different permission mechanisms.

### Claude Code

- **Setup**: Client running
- **Action**: Trigger any tool that would normally require approval (e.g. run a bash command that the PostToolUse hook would intercept)
- **Expected**: PostToolUse hook fires and routes through the approval pipeline if configured
- **Failure modes**: Hook bypasses approval entirely (yolo mode); hook not registered
- **Repro time**: ~30s

### OpenCode

- **Setup**: Client running
- **Action**: Attempt a write operation that the c2c.ts plugin would route for approval
- **Expected**: Plugin permission DM is sent to configured reviewer
- **Failure modes**: Plugin not installed correctly; permission DM not sent
- **Repro time**: ~30s

### Kimi

- **Setup**: Client running with PreToolUse hook configured (`c2c install kimi`)
- **Action**: Run any Shell command (e.g. `ls`)
- **Expected**: For **safe commands** (cat, ls, git status, etc.) — exits 0 immediately, no DM sent. For **unsafe commands** (rm, git push, etc.) — DM sent to reviewer, blocked until verdict
- **Failure modes**:
  - Hook sends DMs for ALL Shell calls (including safe reads) — known issue, hook over-forward bug; safe-pattern allowlist (#591, #587) should fix this
- **Repro time**: ~60s

### Codex

- **Setup**: Client running
- **Action**: Attempt an operation that would route through Codex's MCP approval mechanism
- **Expected**: Approval flow routes correctly (Codex auto-approves MCP tools via TOML)
- **Failure modes**: Approval mechanism not wired up
- **Repro time**: ~30s

---

## 12. broker_root resolution: <Client>

- **Setup**: Client running
- **Action**:
  - `c2c doctor broker-root`
  - Inspect the reported broker root path
- **Expected**:
  - Broker root is `$HOME/.c2c/repos/<fp>/broker` (canonical default) OR matches `C2C_MCP_BROKER_ROOT` if explicitly set
  - The broker root is the same path used by the local c2c binary
- **Failure modes**:
  - Stale `C2C_MCP_BROKER_ROOT` causing split-brain (broker writes to canonical, client polls stale path) — see #581 finding
  - Different fp between clients sharing a git repo clone
- **Repro time**: ~15s

---

## 13. Inbox drain on init: <Client>

- **Setup**:
  - Client A running, client B is the test subject
  - Send messages to client B while it is running normally
  - Leave messages queued in the inbox
- **Action**:
  - `c2c stop <client-B>`
  - Wait 2s
  - `c2c start <client> -n <client-B-name>` (same name/alias)
  - Wait ~10s
  - `c2c poll-inbox` (or wait for auto-delivery)
- **Expected**:
  - Queued messages delivered on session restart
  - No messages lost
- **Failure modes**:
  - Inbox not drained on reconnect
  - Messages dropped during stop/start window
- **Repro time**: ~45s

---

## Aggregate result template

After running all applicable rows, save:

```markdown
# E2E Verification Results — <your-alias> — <date>

## Client summary

| Client | PASS | FAIL | SKIP | Notes |
|--------|------|------|------|-------|
| Claude Code | N | N | N | ... |
| OpenCode    | N | N | N | ... |
| Codex       | N | N | N | ... |
| Kimi        | N | N | N | ... |

## Full log

[PASS|FAIL|SKIP] claude/MCP-attachment: ...
[PASS|FAIL|SKIP] claude/auto-delivery: ...
...
```
