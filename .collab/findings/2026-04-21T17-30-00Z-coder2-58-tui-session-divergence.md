# #58: TUI/Plugin Session Divergence Root Cause

**Status**: FIXED — 7b063ac + b3b2b1a + 7669ec4 (2026-04-21)

## Symptom
After `c2c start opencode --auto -n oc-e2e-test`, Max returned to find:
- TUI showing "Session - New session 2026-04-21T07:18:24Z" (blank/errored)
- Agent "humming server-side but invisible" — work happened in a DIFFERENT session
- `c2c start` resume hint: `Continue opencode -s ses_251186…`

## Root Cause (confirmed from `.opencode/c2c-debug.log`)

### Timeline
```
07:03:43  pid=870867 boots, bootstraps ses_251dfab from HTTP session list
07:05:34  kickoff prompt delivered to ses_251dfab (426 chars)
07:13:13  coordinator1 DM delivered to ses_251dfab → agent works
07:16:39  coordinator1 DM delivered to ses_251dfab → agent works (last turn)
07:18:21  ses_251dfab turn completes (session.updated/diff)
07:18:24  NEW session.created: ses_251186 (root, no parentID)
07:18:24  plugin adopts ses_251186 as new activeSessionId  ← divergence begins
07:18:24  plugin writes ses_251186 → opencode-session.txt
07:18:26  cold-boot delivery to ses_251186: 0 messages, kickoffDelivered=true → NO kickoff
07:18:27  ses_251186: session.error + session.idle (errored immediately)
07:18:27  TUI shows ses_251186 — blank, no messages
```

### Two sessions, one process (pid=870867)
Both `ses_251dfab` and `ses_251186` belong to the same OpenCode process. `ses_251186` is a NEW root session (no parentID) created within the same process 3 seconds after `ses_251dfab`'s last turn completed.

**What created ses_251186?** Unknown from logs alone (agent message contents not stored beyond 120-char preview). Most likely the oc-e2e-test agent ran a command during the 07:16:39 coordinator1 turn that triggered OpenCode to create a new session (e.g., `c2c start opencode`, `opencode session new`, or OpenCode auto-creates after N turns).

### Why `kickoffDelivered` was not reset
`applyRootSessionCreated` (line 549) does NOT reset `kickoffDelivered`. So when `ses_251186` was adopted:
- `deliverKickoffPrompt(ses_251186)` → `if (kickoffDelivered) return;` → skipped
- Agent in `ses_251186` never got the kickoff prompt
- `ses_251186` errored immediately (no user input, promptAsync not called)
- TUI rendered `ses_251186` as a blank new session

## Fix Candidates

1. **Reset `kickoffDelivered = false` in `applyRootSessionCreated`** — minimal fix. New root session always gets the kickoff re-delivered. Risk: if the agent creates sessions repeatedly, kickoff delivered many times.

2. **Guard `applyRootSessionCreated` against session switches** — only adopt a new root session if `pluginState.agent.turn_count === 0` (no turns yet in current session). If turns > 0, ignore new `session.created`. Risk: user can't start a fresh session in the TUI without restarting the plugin.

3. **Delete `opencode-session.txt` on clean exit** — so `c2c start` doesn't resume a stale `ses_OLD` on next boot, avoiding a confusing "which session" question. Doesn't fix the divergence but makes restarts cleaner.

4. **Log the full message content** when delivering via promptAsync (currently truncated to 120 chars) — would help diagnose what triggered `ses_251186` creation.

## Recommendation

Fix 1 + Fix 4 as a minimum viable patch:
- Reset `kickoffDelivered = false` in `applyRootSessionCreated`
- Increase the promptAsync body log from 120 to 500+ chars

Longer term: investigate what in the agent's turn created `ses_251186` and prevent it (agents shouldn't be creating new OpenCode sessions mid-session).

## Files
- Plugin: `run-opencode-inst.d/plugins/c2c.ts`
  - `applyRootSessionCreated`: line 549 — add `kickoffDelivered = false`
  - promptAsync log: line ~795 — increase slice length
- Debug log: `.opencode/c2c-debug.log` and `.opencode/c2c-debug.log.1`
- Captured session: `~/.local/share/c2c/instances/oc-e2e-test/opencode-session.txt`

## NOT the bug (ruled out)
- Double-spawn at OS level: not the case (single fork+exec in c2c_start.ml)  
- `configuredOpenCodeSessionId` filter: C2C_OPENCODE_SESSION_ID is never set by c2c_start.ml, so the filter is never active
- Two plugin instances: the second pid (1042849) is the permission hook process, separate concern
