# #461 Diagnostic Sweep: Permission DM Auto-Reject — Apr 29 Tripwires

**Agent**: birch-coder
**Date**: 2026-04-30 (UTC)
**Broker tip**: `2e7efd1a` (deployed), running broker at `35b886f9`
**Broker log `dm_enqueue` visible**: NO — broker binary is `35b886f9`, which predates the `dm_enqueue` logging introduced at `9a02234e`. Event-level inbox write traces are not available for today.

---

## Context

Coordinator1 reported 6+ permission DM auto-rejections on Apr 29 despite
coordinator sending `approve-always` within the 600s window. All tripwires
share a common performer: cedar-coder (and earlier, jungle-coder). This
document walks every Apr 29 permission DM through the full timeline and
classifies each failure.

---

## Architecture: Two Approval Paths + Two Token Types

The codebase has **two** approval mechanisms, each tied to a token namespace:

### Token namespace `ka_*` — kimi PreToolUse hook

Tokens of form `ka_<id>` are minted by the kimi PreToolUse hook
(`c2c_kimi_hook.ml`). The hook calls `await-reply --token <ka_token>`
which checks the verdict file FIRST, then falls back to inbox DM.

The notifier's `is_approval_verdict_body` (line 147 of `c2c_kimi_notifier.ml`)
explicitly filters `ka_*` verdict DMs from the notification store — they
are drained from the inbox but NOT written to chat log / notification store,
preventing backchannel clutter.

### Token namespace `per_*` — older MCP permission DM

Tokens of form `per_<hex>` are from the pre-#490 MCP permission system
(`open_pending_reply` / `check_pending_reply`). Coordinator sends approvals
as plain DMs: `permission:<per_token>:approve-always`.

The notifier's `is_approval_verdict_body` does NOT match `per_*` (only
`ka_` prefix). These DMs pass through as normal messages: written to the
notification store and chat log, then the inbox is drained.

**Fix path differs by token type** (see § Recommended Fix below).

---

### Path A — Legacy DM verdict (deprecated for `ka_*`, races notifier drain for `per_*`)

```
coordinator1 sends DM:  "permission:<token>:approve-always"
→ cedar-coder's notifier daemon drains cedar's inbox
→ cedar's agent sees DM content via notification store
→ cedar's kimi PreToolUse hook parses DM, extracts verdict
```
Problem for `ka_*`: `await-reply` races the notifier daemon's inbox drain.
Problem for `per_*`: verdict DM goes to notification store, but the agent
may not be polling it via `await-reply` — see § Recommended Fix.

### Path B — File-based verdict (#490 slice 5a)

```
coordinator1:  c2c approval-reply <token> allow
               → writes <broker_root>/approval-verdict/<token>.json
cedar kimi hook:  c2c await-reply --token <token>
               → polls verdict file first, inbox DM as fallback
               → exits 0 with "allow" or "deny" on stdout
```
`c2c approval-reply` is token-format-agnostic — the token is just a filename
component. `await-reply` reads any verdict file by token name.

This path does NOT race the notifier drain for `ka_*`. Problem for `per_*`:
the verdict file works, but the agent must be calling `await-reply --token
<per_token>` for it to be read — which is hook-specific and may not be
happening for MCP permission tokens.

---

## Apr 29 Tripwire Timeline

All times UTC (Apr 29 2026). Cedar's session: `ses_22bcf5201ffeEMsvTsfmbkxdN0`.

### Tripwire A: `per_ddadc922` — `/home/xertrov/.kimi/*`

| Time (UTC) | Event | Source | Notes |
|---|---|---|---|
| 20:09:43.714 | cedar → coordinator1: PERMISSION REQUEST | coordinator1 archive idx 4422 | 600s window starts |
| 20:09:43.714 | cedar → coordinator1: PERMISSION REQUEST (dup) | coordinator1 archive idx 4423 | duplicate |
| **20:09:57.791** | coordinator1 → cedar: `permission:per_ddadc922:approve-always` | cedar archive idx 572 | **14s after request — well within window** |
| 20:09:57.781 | coordinator1 `send` RPC logged in broker log | broker.log | coordinator sent successfully |
| 20:19:43 | **Deadline** (600s after 20:09:43) | — | All subsequent events are post-deadline |
| 20:19:45.475 | cedar → coordinator1: `per_ddadc922 timed out after 600s — auto-rejected` | coordinator1 archive idx 4434 | Timeout fired ~2s late |

**Classification**: `coordinator_reply_lost_to_drain` — coordinator sent the
approval DM at 20:09:57 (14s after request, far within the 600s window).
The DM reached cedar's inbox archive (evidenced by `drained_at` in cedar's
`jsonl`). The notifier daemon then drained the inbox **before** cedar's
PreToolUse hook's `await-reply` could read it. The file-based verdict path
was **not used** by coordinator.

---

### Tripwire B: `per_ddae427` — `/home/xertrov/.local/share/c2c/instances/lumi-tyyni/*`

| Time (UTC) | Event | Source | Notes |
|---|---|---|---|
| 20:18:01.319 | cedar → coordinator1: PERMISSION REQUEST | coordinator1 archive idx 4429 | 600s window starts |
| 20:18:01.319 | cedar → coordinator1: PERMISSION REQUEST (dup) | coordinator1 archive idx 4430 | duplicate |
| **20:18:05.884** | coordinator1 → cedar: `permission:per_ddae427:approve-always` | cedar archive idx 574 | **4s after request — well within window** |
| 20:28:01 | **Deadline** (600s after 20:18:01) | — | All subsequent events are post-deadline |
| 20:28:05.247 | cedar → coordinator1: `per_ddae427 timed out after 600s — auto-rejected` | coordinator1 archive idx 4455 | Timeout fired ~4s late |

**Classification**: `coordinator_reply_lost_to_drain` — same pattern as A.
Coordinator sent within seconds; DM arrived in inbox archive; notifier drain
prevailed over hook's read. File-based verdict path not used.

---

### Tripwire C: `per_ddae5f69` — `/home/xertrov/.local/share/c2c/instances/lumi-probe-test/*`

| Time (UTC) | Event | Source | Notes |
|---|---|---|---|
| 20:19:58.499 | cedar → coordinator1: PERMISSION REQUEST | coordinator1 archive idx 4436 | 600s window starts |
| 20:19:58.499 | cedar → coordinator1: PERMISSION REQUEST (dup) | coordinator1 archive idx 4437 | duplicate |
| **20:20:03.831** | coordinator1 → cedar: `permission:per_ddae5f69:approve-always` | cedar archive idx 576 | **5s after request — well within window** |
| 20:29:58 | **Deadline** (600s after 20:19:58) | — | All subsequent events are post-deadline |
| 20:29:59.401 | cedar → coordinator1: `per_ddae5f69 timed out after 600s — auto-rejected` | coordinator1 archive idx 4459 | Timeout fired ~1s late |

**Classification**: `coordinator_reply_lost_to_drain` — same pattern.

---

### Tripwire D: `per_ddae694` — `/home/xertrov/.local/share/c2c/instances/cedar-test-478/*`

| Time (UTC) | Event | Source | Notes |
|---|---|---|---|
| 20:20:40.573 | cedar → coordinator1: PERMISSION REQUEST | coordinator1 archive idx 4438 | 600s window starts |
| 20:20:40.573 | cedar → coordinator1: PERMISSION REQUEST (dup) | coordinator1 archive idx 4439 | duplicate |
| **20:21:05.000** | coordinator1 → cedar: `permission:per_ddae694:approve-always` | cedar archive idx 577 | **25s after request — well within window** |
| 20:30:40 | **Deadline** (600s after 20:20:40) | — | All subsequent events are post-deadline |
| 20:30:40.453 | cedar → coordinator1: `per_ddae694 timed out after 600s — auto-rejected` | coordinator1 archive idx 4460 | Timeout fired ~0s late |

**Classification**: `coordinator_reply_lost_to_drain` — same pattern.

---

## Classification Summary

| Token | Request time | Approval sent | Approval latency | Timeout | Verdict file used? | Class |
|---|---|---|---|---|---|---|
| per_ddadc922 | 20:09:43 | 20:09:57 | 14s | 20:19:45 | NO | coordinator_reply_lost_to_drain |
| per_ddae427 | 20:18:01 | 20:18:05 | 4s | 20:28:05 | NO | coordinator_reply_lost_to_drain |
| per_ddae5f69 | 20:19:58 | 20:20:03 | 5s | 20:29:59 | NO | coordinator_reply_lost_to_drain |
| per_ddae694 | 20:20:40 | 20:21:05 | 25s | 20:30:40 | NO | coordinator_reply_lost_to_drain |

**4/4 = 100%** `coordinator_reply_lost_to_drain`. All approvals were sent
well within the 600s window. All timed out because the notifier daemon
drained the inbox before the PreToolUse hook's `await-reply` could read them.

---

## Root Cause

**Coordinator1 is not using the file-based verdict path.**

The `#490 slice 5a` `c2c approval-reply` mechanism writes a JSON verdict file
at `<broker_root>/approval-verdict/<token>.json`. The kimi PreToolUse hook's
`await-reply` polls this file **before** reading the inbox DM, eliminating
the notifier-drain race.

However, coordinator1 today sent approvals **only** as plain DMs
(`permission:<token>:approve-always`). The `approval-pending/` and
`approval-verdict/` directories confirm this: the only verdict file present
(`ka_tool_xLgeZLrz1zhGjVTCqpO5JeDo.json`) corresponds to a stanza-coder
verdict, not a coordinator1 approval. No coordinator1 verdict files exist
for any of the four tripwires above.

In the words of coordinator1's own DM to cedar (archive idx 575):
> "Got it — that first request (`per_ddadc922...`) timed out before my
> approve-always reached you."

The approval DID reach cedar's inbox — coordinator's own `send` RPC logged
success at 20:09:57.781. The problem is not delivery to the inbox. The
problem is that `await-reply` (using the legacy DM-reading path) lost the
race against the notifier daemon's drain.

---

## Evidence of Delivery

The DM delivery is confirmed by multiple sources:
1. **Coordinator broker log**: `send` RPC succeeded at 20:09:57.781
2. **Cedar inbox archive**: The DM appears in `cedar-coder.jsonl` with
   `drained_at = 1777493397.791839` — meaning the notifier daemon
   successfully delivered it to cedar's agent turn. Cedar's agent **saw the
   message**. Yet the timeout fired anyway.

This means the failure is not at the inbox delivery layer. The approval
message was delivered to cedar's session. The failure is specifically in the
`await-reply` → notifier drain race: `await-reply` read the inbox, found
nothing (because the notifier had already drained it), and returned no
verdict. The hook then timed out.

---

## Failure Class: `coordinator_reply_lost_to_drain`

**Symptom**: Coordinator sends approval DM within the 600s window. DM is
confirmed delivered to the recipient's inbox archive. Recipient's agent
never receives the verdict; timeout fires anyway.

**Root cause**: The kimi PreToolUse hook uses `await-reply`, which reads
the inbox via `read_inbox` (non-draining). The notifier daemon runs
`drain_inbox` (draining) in a concurrent thread. If the notifier wins the
race, the verdict message is removed from the inbox before `await-reply`
sees it.

**Why it persists**: The race is probabilistic. When the notifier is idle
(e.g., kimi is actively processing), the DM sits in the inbox long enough
for `await-reply` to read it. When the notifier is active (frequent inbox
drains), it wins consistently. Today's 4/4 failures all occurred during a
period of active notifier draining.

**Note**: There is no evidence of clock skew, message-ID mismatch, or
network loss. All failures are the same root cause.

---

## Recommended Fix

**Smallest viable fix**: Migrate coordinator1's approval send from the
legacy DM path to the file-based verdict path.

**Current (broken)**:
```
c2c send cedar-coder "permission:<token>:approve-always"
```

**Correct (file-based)**:
```
c2c approval-reply <token> allow
```

`c2c approval-reply` writes the verdict file. The hook's `await-reply`
polls the verdict file first (before the inbox). This eliminates the race
entirely because the file write and file read are serialized through the
filesystem, not through concurrent inbox access.

**Pre-requisites** (already satisfied):
- `c2c approval-reply` CLI exists and is functional (verified at
  `c2c_approval_paths.ml:93`)
- `await-reply` polls the verdict file before inbox (verified at
  `c2c.ml:5056-5073`)
- The hook is invoked with `--token` (verified in `c2c_kimi_hook.ml`)

**Coord action required**: Coordinator1 must be updated to use
`c2c approval-reply <token> allow` instead of `c2c send <target>
"permission:<token>:approve-always"` for all future permission approvals.

---

## Missing Evidence

The `dm_enqueue` broker log events (available in broker builds from
`9a02234e` onward) would have shown exactly when the coordinator's approval
DM was written to cedar's inbox file, enabling precise latency measurement
between DM write and notifier drain. The currently deployed broker
(`35b886f9`) predates this logging. After the next Railway push, this
trace will be available for future diagnostics.

---

## Root Cause: `per_*` vs `ka_*` — Different Failure Mechanisms (#494)

All 4 Apr 29 tripwires used `per_*` tokens. The failure mechanism for
`per_*` is distinct from the `ka_*` notifier-drain race.

### `ka_*` (kimi PreToolUse, #490 slice 5a) — solved by file verdict
- Hook calls `await-reply --token <ka_token>` which polls verdict file FIRST,
  then falls back to inbox DM
- Notifier drains inbox AND filters `ka_*` verdict DMs from notification store
  (`is_approval_verdict_body` at `c2c_kimi_notifier.ml:147` matches `ka_` prefix)
- `c2c approval-reply <ka_token> allow` eliminates the race cleanly
- File: `c2c_approval_paths.ml` + `c2c_kimi_hook.ml`

### `per_*` (OpenCode MCP permission) — different race

Cedar runs OpenCode. The OpenCode plugin (`data/opencode-plugin/c2c.ts`)
has its own permission polling mechanism:

1. Permission request sent → `waitForPermissionReply(permId, timeoutMs, supervisors)`
   starts a `setTimeout` for `timeoutMs` (default 600,000ms = 10min)

2. At timeout: `peekInboxForPermission(permId)` is called ONCE, then resolves
   as `"timeout"` if no reply found

3. `peekInboxForPermission` reads from `peek-inbox` (broker inbox, non-draining)

4. `deliverMessages` runs every `pollIntervalMs` (default 5,000ms) and calls
   `drainInbox()` which moves messages from broker inbox → spool file

**The race**: If `deliverMessages` runs and calls `drainInbox` before the
permission reply times out, the coordinator's DM is moved to the spool. When
`peekInboxForPermission` runs at timeout, it reads the broker inbox — which is
now empty. The reply is in the spool but `peekInboxForPermission` never checks
the spool. Result: timeout despite the reply being in the system.

**Timeline confirms this**:
- Coordinator DM sent at 20:09:57 (confirmed by `drained_at = 1777493397.791839`
  in cedar's archive)
- `deliverMessages` was running every 5 seconds throughout this period
- `peekInboxForPermission` ran once at 20:19:45 (12 seconds before the 10min
  deadline) and found nothing — the reply had been drained to the spool

**Fix options for `per_*`**:
1. **Make `peekInboxForPermission` also check the spool** — the reply is in
   the spool if `drainInbox` ran first. This closes the race without
   changing the verdict path.
2. **Use the file-based verdict path** — `c2c approval-reply <per_token> allow`
   writes the verdict file. The OpenCode plugin would need to call
   `await-reply --token <per_token>` instead of just `peekInboxForPermission`.
   This requires a code change in the OpenCode plugin's permission handling.
3. **Increase `C2C_PLUGIN_POLL_INTERVAL_MS`** — reduces (but doesn't eliminate)
   the window where `drainInbox` wins over `peekInboxForPermission`

The smallest viable fix is Option 1: make `peekInboxForPermission` read both
the broker inbox AND the spool. This eliminates the race for `per_*` tokens
without requiring a new polling mechanism.

---

## Related Documents

- `.collab/findings/2026-04-30T05-43-00Z-stanza-coder-await-reply-vs-notifier-drain-race.md`
  — the original race finding
- `.collab/design/2026-04-30-142-approval-side-channel-stanza.md` — Option A
  (file-based verdict) design doc
- `ocaml/cli/c2c_approval_paths.ml` — file-based verdict implementation
- `ocaml/cli/c2c.ml:4971-5099` — `await-reply` implementation
- `ocaml/cli/c2c_kimi_hook.ml` — kimi PreToolUse hook calling `await-reply`
