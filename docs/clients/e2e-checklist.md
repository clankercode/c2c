---
title: Client E2E Verification Checklist
description: Reproducible smoke battery for verifying each client is a first-class c2c peer
layout: page
---

# Client E2E Verification Checklist

Source of truth: [`docs/clients/feature-matrix.md`](./feature-matrix.md).
Clients: **Claude Code**, **Codex**, **Pi Agent**, **OpenCode**, **Kimi**.

Last updated: 2026-07-11 (T005 Codex app-server delivery rows)

---

## How to run

Each row is a discrete tmux-pane smoke test. For MCP-managed clients, run each
client in its own tmux pane via `c2c start <client> -n <test-alias>`. For Pi
Agent, install and run the `pi-c2c` extension with pi's own launcher instead of
`c2c start`. Capture results with `./scripts/c2c_tmux.py peek <pane-name>` when
the client is tmux-managed.

Use ephemeral test aliases (e.g. `test-claude-$(date +%s)`). Clean up
MCP-managed clients with `c2c stop <test-alias>` when done; stop Pi Agent
through the pi session that loaded `pi-c2c`.

Result format per row:

```
[PASS|FAIL|SKIP] <client>/<feature>: <one-line note> (<repro-time>)
```

Aggregate results to `.collab/research/2026-05-01-e2e-verification-results-<your-alias>.md`
after a full run.

---

## Common setup (all clients)

```bash
# Verify the binary is current + confirm broker root is correct
c2c doctor

# Check no stale sessions
c2c list --all
```

---

## 1. Client attachment: <Client>

- **Setup**:
  - MCP-managed clients: `c2c install <client>` (in a test repo)
  - MCP-managed clients: `c2c start <client> -n test-<client>-<rand>`
  - Pi Agent: `pi install npm:pi-c2c`, then launch pi with the extension loaded
- **Action**:
  - `c2c whoami`
- **Expected**:
  - Returns a valid c2c alias (not empty, not an error)
  - Pi Agent registers through `pi-c2c` / the `c2c` CLI, not through MCP
- **Failure modes**:
  - MCP-managed clients: MCP binary not on PATH -> "command not found"
  - Codex hooks missing/untrusted → no automatic hook delivery; use explicit polling until hook setup is fixed
  - Pi Agent: `pi-c2c` extension not installed or `C2C_BIN` points to a bad binary
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
  - For Codex in hook mode (vanilla, or managed on a Codex too old for the app-server transport): installed hooks (`c2c hook codex`) drain and inject via `hookSpecificOutput.additionalContext` on the next hook fire (turn boundary) — NOT on arrival. An idle session surfaces the message on its next turn (or via the tmux/herdr wake nudge when `delivery_mode=hooks+wake`).
  - For managed Codex on a supported Codex (app-server transport, the default — B131): the message is injected into the thread's model-visible history on arrival — it does **not** render in the TUI transcript. Verify with a follow-up turn (ask the model to echo the marker), not by watching the pane. Any typed composer draft must survive byte-exact; eligible local mail on an idle thread also starts one gated auto-turn (T007).
  - For Pi Agent: `pi-c2c` drains the inbox and injects via `pi.sendMessage`
  - For Kimi: message appears in notification store / TUI prefill
- **Failure modes**:
  - ECHILD race on Claude (known, fixed via bash wrapper)
  - Channel-push selective miss (#387, known fixed)
  - Codex hooks not installed or not trusted (`c2c doctor hooks` classifies the live delivery mode and prints the remediation)
- **Repro time**: ~30s

---

## 2b. Codex app-server delivery (managed, default on supported Codex)

**Applies to** managed Codex on codex-cli ≥ 0.144 — the app-server transport is
the default managed path (B131 wired the supervision loop; no flag). On older
codex expect the minimum-version message + hook fallback, and mark this row
SKIP. The library-level harness `scripts/codex-autoturn-e2e.py` (inside tmux)
proves the same contract against a real codex if you want a supervision-free
check.

- **Setup**:
  - Inside tmux: `c2c start codex -n test-cx-appserver-<rand>`
    (codex ≥ 0.144 required; on older codex expect the minimum-version
    message + hook fallback, and mark this row SKIP)
  - `c2c dev instances --json` shows `"delivery_mode": "app-server"` and
    `"app_server_status": "online-attached"` for the instance
- **Action**:
  - Type a distinctive draft into the composer and leave it unsubmitted
  - From another terminal: `c2c send <instance-alias> "e2e marker C2C_E2E_<rand>"`
  - Wait ~5s; snapshot the pane (`./scripts/tui-snapshot.sh` or `c2c_tmux.py peek`)
  - Submit a turn asking the model to echo any `C2C_E2E_` marker it can see
- **Expected**:
  - The draft is byte-identical after the arrival (composer untouched)
  - The message does NOT appear in the transcript at arrival (model-history-only)
  - No turn starts on arrival while you are mid-draft with the thread idle only
    if the mail is remote-origin or DND is on; **local** mail on an idle thread
    may start one gated turn (that is the T007 contract, not a failure)
  - The echo turn reproduces the `C2C_E2E_` marker (mail is model-visible)
  - `c2c doctor hooks` reports the instance as `app-server` with no remediation
- **Failure modes**:
  - `app_server_status=failed-startup` → codex too old / capability probe
    failed; `c2c doctor hooks` shows `app-server-unavailable` + remediation
  - Draft clobbered or transcript shows the raw injection → file a finding
    immediately (violates the T004 draft-safety proof)
- **Repro time**: ~90s

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
  - `c2c rooms join e2e-test-room-<rand>`
  - `c2c rooms send e2e-test-room-<rand> "hello room"`
  - `c2c rooms history e2e-test-room-<rand> --limit 5`
  - `c2c rooms list` (check membership)
  - `c2c rooms leave e2e-test-room-<rand>`
- **Expected**:
  - `join_room` succeeds (no error)
  - `send_room` returns delivered count > 0
  - `room_history` shows the sent message
  - `rooms list` shows `e2e-test-room-<rand>`
  - `rooms leave` succeeds
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
  - Set DND on first via MCP: `mcp__c2c__set_dnd` (MCP-only, no CLI equivalent)
  - Pi Agent: SKIP until a Pi-side DND control is verified
- **Action**:
  - From another terminal: `c2c send <client-alias> "deferrable test" --deferrable`
  - Check DND status via MCP: `mcp__c2c__dnd_status` (MCP-only)
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
  - Pi Agent: SKIP until a Pi-side DND control is verified
- **Action**:
  - Set DND on via MCP: `mcp__c2c__set_dnd` (MCP-only, no CLI equivalent)
  - From another terminal: `c2c send <client-alias> "DND test"`
  - Wait ~10s
  - `c2c poll-inbox` on client → should NOT auto-deliver
  - Set DND off via MCP: `mcp__c2c__set_dnd` (MCP-only)
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
  - MCP-managed clients: fresh alias via `c2c install <client>` with a named instance
  - Pi Agent: set `C2C_PI_ALIAS=test-pi-<rand>` before launching pi with `pi-c2c`
  - `c2c list` shows the alias
- **Action**:
  - MCP-managed clients: `c2c stop <test-alias>`
  - Wait 2s
  - MCP-managed clients: `c2c start <client> -n <test-alias>` (same name)
  - Pi Agent: restart the pi session with the same `C2C_PI_ALIAS`
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
  - Pi Agent: SKIP until `pi-c2c` auto-join room behavior is verified
- **Action**:
  - `c2c rooms list`
- **Expected**:
  - `swarm-lounge` appears in the rooms list
  - If the client joined on first session (auto-join via `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`), it should be there immediately
- **Failure modes**:
  - `swarm-lounge` not in `rooms list` → `C2C_MCP_AUTO_JOIN_ROOMS` not set correctly
- **Repro time**: ~15s

---

## 10. Managed-instance lifecycle: <Client>

Pi Agent is not a `c2c start` target; mark this row SKIP for Pi Agent and test
the pi launcher / extension lifecycle separately.

- **Setup**:
  - MCP-managed clients: use the test pane running from step 1
- **Action**:
  - MCP-managed clients: `c2c stop <test-alias>`
  - Wait 2s
  - MCP-managed clients: `c2c start <client> -n <test-alias>`
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

### Codex

- **Setup**: Client running
- **Action**: Attempt an operation that would route through Codex's MCP approval mechanism
- **Expected**: Approval flow routes correctly (Codex auto-approves MCP tools via TOML)
- **Failure modes**: Approval mechanism not wired up
- **Repro time**: ~30s

### Pi Agent

- **Setup**: Pi Agent running with `pi-c2c`
- **Action**: N/A for MCP permission prompts
- **Expected**: Mark SKIP unless a Pi-side permission flow is explicitly configured and documented
- **Failure modes**: Do not treat MCP approval absence as a Pi Agent failure
- **Repro time**: ~0s

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

---

## 12. broker_root resolution: <Client>

- **Setup**: Client running
- **Action**:
  - `c2c doctor`
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
  - MCP-managed clients: `c2c stop <client-B>`
  - Wait 2s
  - MCP-managed clients: `c2c start <client> -n <client-B-name>` (same name/alias)
  - Pi Agent: restart the pi session with the same `C2C_PI_ALIAS`
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
| Codex       | N | N | N | ... |
| Pi Agent    | N | N | N | ... |
| OpenCode    | N | N | N | ... |
| Kimi        | N | N | N | ... |

## Full log

[PASS|FAIL|SKIP] claude/MCP-attachment: ...
[PASS|FAIL|SKIP] claude/auto-delivery: ...
...
```
