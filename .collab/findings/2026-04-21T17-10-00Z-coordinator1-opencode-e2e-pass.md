---
author: coordinator1
ts: 2026-04-21T17:10:00+10:00
severity: success
status: PASS
---

# OpenCode plugin E2E — two-round round-trip PASS

First genuine cold-boot E2E since the session-id collision, identity
refresh (#55), deferred broadcasts (#56), and session-id derivation
batch landed. Launched `c2c start opencode --auto -n oc-e2e-test`
from bash in a fresh tmux pane.

## Sequence

1. `c2c start opencode --auto -n oc-e2e-test` — fish pane 0:1.6
2. Role prompt fired (#54): answered `tester`, saved to `.c2c/roles/oc-e2e-test.md`
3. OpenCode TUI came up, 2 MCP servers connected
4. Registry check: `oc-e2e-test alive pid=868476` — correct alias, real pid ✓
5. coordinator1 → `mcp__c2c__send` to oc-e2e-test
6. Plugin delivered via promptAsync (TUI thinking-spinner visible)
7. oc-e2e-test LLM called `mcp__c2c__send` to coordinator1
8. coordinator1 received the reply via PostToolUse hook inbox-inject
9. Round 2: asked for `whoami` — got back exact `oc-e2e-test` ✓

## What this proves works end-to-end

- [x] Managed-session launch via `c2c start opencode`
- [x] Role-interview prompt (#54) on first launch
- [x] Correct alias + pid registration (#55 identity refresh)
- [x] `C2C_MCP_AUTO_REGISTER_ALIAS` propagation into opencode MCP child env
- [x] Plugin c2c.ts active (sidecar alias correct)
- [x] `c2c monitor` subprocess watching inbox, firing promptAsync on `📬`
- [x] OpenCode LLM uses `mcp__c2c__send` tool correctly
- [x] coordinator1's PostToolUse hook drains inbox on each turn
- [x] Two-phase registration (#52) — no spurious joins for provisional
- [x] `whoami` returns correct alias inside opencode session

## Minor observation (not a bug)

In round 1, the reply body string said "Ack from test-role-agent" — the
LLM hallucinated a name in its prose, even though the c2c envelope
correctly reported `from=oc-e2e-test`. Round 2 with explicit whoami
call returned the correct alias. This is a prompt-hygiene thing, not a
c2c bug.

## Pane / peer disposition

- oc-e2e-test is LEFT RUNNING in tmux pane 0:1.6 at Max's request
  ("I want to see an opencode agent humming when I get back"). Its PID
  was 868476 at boot. Max can DM it, peek it, stop it with
  `c2c stop oc-e2e-test` when done.

## Cross-client pass (addendum)

Further validated within minutes of the above:

- oc-e2e-test → coder2-expert-claude (DM, OC → Claude) ✓
- oc-e2e-test → swarm-lounge (room fan-out) ✓
- opencode-c2c/planner1 → oc-e2e-test (DM, Claude → OC) ✓
- oc-e2e-test → opencode-c2c (reply) ✓

So: both directions of OC ↔ Claude work, room fan-out works, and the
late peer_register broadcast (deferred via #56 until provisional →
active promotion) fired on first poll_inbox as designed.

## Ralph-loop promise context

Earlier this session a ralph-loop was asking for OC_Q_E2E_TESTED. That
loop had already been superseded by Max switching to an open-ended
spirit-quest framing, but for the record: E2E is now genuinely true.
