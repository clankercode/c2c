# Research: Permission Approve Timeout Bug (#461)

**Investigated by**: jungle-coder
**Date**: 2026-04-29
**Bug**: In-window permission approvals treated as 600s timeout

---

## Executive Summary

The bug is **confirmed and root-caused**. The primary failure mode is a **timeout mismatch** between `await_supervisor_reply` (300s hardcoded) and the pending permission TTL (600s default). A secondary contributor is coordinator inbox-delivery lag (DND, compacting, or idle polling gaps causing the coordinator to not surface the permission DM before the TTL expires). The `coord_fallthrough.ml` module was designed to address exactly this failure mode but the `await_supervisor_reply` timeout mismatch is the more immediate fix needed.

---

## Code Path Walkthrough

### 1. Pending Permission Creation

`c2c_deliver_inbox.py:forward_permission_to_supervisors` (L1038-1082):

```python
perm_id = f"codex-{event.get('request_id', 'unknown')}"
# ...
run_c2c_command([
    "open-pending-reply", perm_id,
    "--kind", "permission",
    "--supervisors", ",".join(supervisors),  # hardcoded ["coordinator1"]
])
for sup in supervisors:
    run_c2c_command(["send", sup, msg])
```

The broker's `open_pending_reply` handler (`c2c_mcp.ml:7094-7184`) creates the entry:

```ocaml
let pending : pending_permission = {
  perm_id; kind; requester_session_id = session_id;
  requester_alias = alias; supervisors;
  created_at = now; expires_at = now +. ttl_seconds;  (* TTL default = 600s *)
  fallthrough_fired_at = []; resolved_at = None
}
```

`default_permission_ttl_s = 600.0` at `c2c_mcp.ml:355`.

### 2. Approval DM Sending

The supervisor receives the permission request DM and sends back:
```
permission:<perm_id>:approve-once
```
to the requester's alias.

### 3. Approval DM Waiting — THE BUG

`c2c_deliver_inbox.py:await_supervisor_reply` (L963-992):

```python
def await_supervisor_reply(
    perm_id: str, timeout_ms: int, supervisors: list[str],
    session_id: str, broker_root: Path,
) -> str:
    deadline = time.time() + (timeout_ms / 1000)  # 300s hardcoded timeout_ms
    supervisor_set = set(supervisors)
    while time.time() < deadline:
        rc, stdout, _ = run_c2c_command(["poll-inbox", "--json", "--session-id", session_id])
        # ... parse messages, look for pattern match ...
        if match and match.group(1) == perm_id:
            return match.group(2)
        time.sleep(1)
    return "timeout"  # ← returns TIMEOUT after 300s even if entry valid for 600s
```

The `timeout_ms = 300000` (300s) is hardcoded at L625 and L640 — **5 minutes**, not matching the 600s TTL.

### 4. Broker-side Permission Check

`c2c_mcp.ml:984-988`:

```ocaml
let find_pending_permission t perm_id =
  with_pending_lock t (fun () ->
    let now = Unix.gettimeofday () in
    List.find_opt (fun p -> p.perm_id = perm_id && p.expires_at > now)
      (load_pending_permissions t))
```

Uses `>` (strictly greater than). If `now >= expires_at`, entry is treated as expired.

---

## Root Cause Candidates (Ranked by Likelihood)

### Candidate 1: `await_supervisor_reply` Timeout Mismatch [PRIMARY — Likelihood: HIGH]

**Mechanism**: `await_supervisor_reply` has a 300s timeout. The pending permission TTL is 600s. If the coordinator is slow to respond (but still within the 600s TTL), the requester times out at 300s and returns "timeout" to Codex. The coordinator then approves (still within TTL), but the requester has already abandoned the wait.

**Timeline**:
- T=0: Permission DM sent to coordinator1
- T=0-300s: Coordinator is DND/compacting/busy — not polling inbox
- T=300s: `await_supervisor_reply` returns "timeout" to Codex
- T=350s: Coordinator finally polls inbox, sees permission DM, approves
- T=350s: Approval DM sent to requester — **but requester already done waiting**
- T=600s: Pending entry expires

**Fix**: Change `await_supervisor_reply` to use a timeout that matches or exceeds the TTL. The TTL can be read from the `open-pending-reply` response (which returns `expires_at`), or we can pass `C2C_PERMISSION_TTL` env var to the deliver inbox process and use that.

**Code references**:
- `c2c_deliver_inbox.py:625` — hardcoded `timeout_ms=300000`
- `c2c_deliver_inbox.py:640` — hardcoded `timeout_ms=300000`
- `c2c_mcp.ml:355` — `default_permission_ttl_s = 600.0`

---

### Candidate 2: Coordinator Inbox-Delivery Lag [SECONDARY — Likelihood: HIGH]

**Mechanism**: Even with a 300s timeout, the coordinator might not receive the permission DM until after the 600s TTL expires if the coordinator is DND, compacting, or has `auto_drain_channel=false` and isn't polling inbox.

The `coord_fallthrough.ml` module (L6-12 comment) was **designed specifically for this failure mode**:

> "Receipt: galaxy-coder's permission DM auto-rejected at TTL=600s on 2026-04-29 because the primary coord didn't surface the inbound in time. Per Max's brief, the fix is redundancy — if the primary doesn't ack within `coord_fallthrough_idle_seconds`, fan out to backups..."

The fallthrough scheduler (60s tick) fires backup tiers if the primary doesn't respond within `idle_seconds` (default 120s). However, this only helps if the fallthrough scheduler is running AND the backup coordinators call `check_pending_reply` correctly.

**Fix**: The `coord_fallthrough` design is the correct long-term fix. The immediate fix for the timeout mismatch (Candidate 1) reduces the urgency but does not eliminate this path.

**Code references**:
- `coord_fallthrough.ml:35` — `default_tick_seconds = 60.0`
- `coord_fallthrough.ml:95` — `if p.resolved_at <> None then `No_action``
- `c2c_mcp.ml:984-988` — `find_pending_permission` expiry check

---

### Candidate 3: Race Condition — Entry Expires Between Coordinator Approval and `check_pending_reply` Call [LOW — Likelihood: LOW]

**Mechanism**: If the coordinator surfaces the permission DM very close to the TTL boundary, and the agent's call to `check_pending_reply` happens just after `now >= expires_at`, the approval would be rejected as expired.

However, `find_pending_permission` checks `expires_at > now` using broker time, and the window is sub-second, so this is unlikely to be the 5-reproducitons/day root cause.

**Fix**: If this is the actual bug, the fix would be to use `>=` instead of `>` in the expiry check, or to add a grace period.

**Code reference**: `c2c_mcp.ml:987` — `p.expires_at > now`

---

### Candidate 4: Clock Skew Between Broker and Coordinator [LOW — Likelihood: LOW]

**Mechanism**: If the coordinator's system clock is significantly ahead of the broker's clock, the `expires_at` computed by the broker at `created_at + TTL` might appear to expire earlier from the coordinator's perspective (if `check_pending_reply` uses coordinator time). But `check_pending_reply` uses `Unix.gettimeofday()` on the broker, so this shouldn't matter for the expiry check.

If the **requester's** clock is ahead, the `created_at` embedded in the entry might be slightly in the future relative to broker time, making the entry appear to have slightly less than 600s of lifetime. But this would only matter for extremely skewed clocks (>1s), which is unlikely.

**Fix**: N/A unless evidence points to this.

---

### Candidate 5: Inbox Watcher Delay (`C2C_MCP_INBOX_WATCHER_DELAY`) [VERY LOW — Likelihood: VERY LOW]

**Mechanism**: The inbox watcher introduces a delay (default 2.0s, or 30.0s if `C2C_MCP_INBOX_WATCHER_DELAY` is set to an unparseable value per `c2c_mcp_server_inner.ml:89-95`). This delay affects **delivery** to the coordinator's inbox, not the expiry check itself.

The coordinator's agent would still receive the DM on the next `poll-inbox` call. The 2s delay is negligible compared to the 600s TTL.

**Fix**: N/A unless `C2C_MCP_INBOX_WATCHER_DELAY` is being set to a very large value.

**Code reference**: `c2c_mcp_server_inner.ml:89-95`

---

## Specific Fix Proposals

### Fix for Candidate 1 (Primary)

In `c2c_deliver_inbox.py:forward_permission_to_supervisors`, change `timeout_ms` from hardcoded `300000` to match or exceed the pending permission TTL:

```python
# After calling open-pending-reply, parse the response to get expires_at
# or use C2C_PERMISSION_TTL env var (default 600s) + safety margin
import os
ttl_s = float(os.environ.get("C2C_PERMISSION_TTL", "600"))
timeout_ms = int((ttl_s + 60) * 1000)  # TTL + 60s safety margin
```

The `open-pending-reply` response includes `expires_at` (line 7155), so we could parse it:

```python
rc, stdout, _ = run_c2c_command([
    "open-pending-reply", perm_id,
    "--kind", "permission",
    "--supervisors", ",".join(supervisors),
])
# Parse stdout to get expires_at, compute remaining TTL, add margin
```

**Risk**: Low. This just extends the wait window.

### Fix for Candidate 2 (Secondary)

Ensure `coord_fallthrough` is enabled and the backup chain is configured. Check `.c2c/config.toml`:

```toml
[swarm]
coord_chain = ["coordinator2", "coordinator3"]  # backups
coord_fallthrough_idle_seconds = 120.0          # fire backup if primary silent > 2min
coord_fallthrough_broadcast_room = "swarm-lounge"
```

The fallthrough scheduler fires at 60s intervals. At default `idle_seconds=120.0`, a backup would be notified at T=120s if the primary hasn't called `check_pending_reply`. This gives 480s of remaining TTL for the backup to approve.

**Risk**: Low. The fallthrough mechanism is designed for exactly this.

### Fix for Candidate 3 (Very Low Probability)

In `c2c_mcp.ml:987`, change strict `>` to `>=`:

```ocaml
List.find_opt (fun p -> p.perm_id = perm_id && p.expires_at >= now)
```

But this would make `now == expires_at` return valid, which is a boundary condition. A safer fix is a grace period:

```ocaml
let grace_period_s = 5.0 in
List.find_opt (fun p -> p.perm_id = perm_id && p.expires_at +. grace_period_s > now)
```

**Risk**: Medium. Changes the expiry semantics.

---

## Code References Summary

| Component | File:Line | Description |
|-----------|-----------|-------------|
| TTL default | `c2c_mcp.ml:355` | `default_permission_ttl_s = 600.0` |
| Pending entry creation | `c2c_mcp.ml:7127-7132` | `expires_at = now +. ttl_seconds` |
| Expiry check | `c2c_mcp.ml:987` | `p.expires_at > now` (strict `>`) |
| `find_pending_permission` | `c2c_mcp.ml:984-988` | Lock-protected find with expiry filter |
| Hardcoded timeout | `c2c_deliver_inbox.py:625,640` | `timeout_ms=300000` (300s) |
| `await_supervisor_reply` | `c2c_deliver_inbox.py:963-992` | 300s polling loop with 1s sleep |
| Pattern match | `c2c_deliver_inbox.py:983-988` | `permission:([a-zA-Z0-9_-]+):(approve-once\|...)` |
| `forward_permission_to_supervisors` | `c2c_deliver_inbox.py:1038-1082` | Orchestrates open-reply → send → await |
| Fallthrough scheduler | `coord_fallthrough.ml:249-295` | 60s tick; fires backup at `idle_seconds` |
| Fallthrough default idle | `c2c_start.ml:689` | `default_coord_fallthrough_idle_seconds = 120.0` |
| Inbox watcher delay | `c2c_mcp_server_inner.ml:89-95` | Default 2.0s; unparseable → 30.0s |

---

## Recommendation

**Fix Candidate 1 first** — extend `await_supervisor_reply` timeout to match the TTL.

1. In `c2c_deliver_inbox.py:forward_permission_to_supervisors`, pass a timeout that exceeds the TTL. Simplest approach: read `C2C_PERMISSION_TTL` env var (default 600s) and set `timeout_ms = (ttl + 60) * 1000`.

2. **Additionally**, verify that `coord_fallthrough` is configured in `.c2c/config.toml` with a proper backup chain, since the fallthrough is the redundancy mechanism for when the coordinator is truly unavailable.

3. **Optionally** consider reducing the TTL to something closer to expected coordinator response time (e.g., 180s) with the fallthrough handling longer wait — but this changes the TTL semantics and should be discussed with the team.

The 5 reproductions today are likely all Candidate 1: coordinator slowly surfaces the DM (DND, compacting, or just slow polling), requester times out at 300s, coordinator approves at ~350s, approval lost.

---

## Fix Applied

**Committed**: `11173747` on `slice/461-permission-timeout` (worktree `.worktrees/461-permission-timeout/`)

Implemented the Candidate 1 fix exactly as recommended above:

- Added module-level `_PERMISSION_TTL_S` and `_PERMISSION_TIMEOUT_MS` constants that read `C2C_PERMISSION_TTL` env var (default 600s) + 60s margin = 660s default
- Replaced both hardcoded `timeout_ms=300000` call sites with `_PERMISSION_TIMEOUT_MS`
- Updated function signature default for consistency

**Not included in this slice** (optional follow-up):
- Grace period in `find_pending_permission` (strict `>` → `>=` or grace period) — low probability per Candidate 3 analysis
- `coord_fallthrough` config verification — falls under separate slice if needed
