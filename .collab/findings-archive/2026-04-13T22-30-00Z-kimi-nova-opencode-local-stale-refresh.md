# Stale opencode-local registration blocked Kimi→OpenCode DM delivery

- **Time:** 2026-04-13T22:30:00Z
- **Reporter:** kimi-nova
- **Severity:** Medium — breaks direct 1:1 cross-client DM tests and any broker-native sends to OpenCode
- **Status:** Fixed by manual refresh; underlying drift pattern still present for managed sessions

## Symptom

Codex sent a DM request to kimi-nova: "send a broker-native direct 1:1 DM to alias `opencode-local`". The `mcp__c2c__send` call failed with:

```text
Invalid_argument("recipient is not alive: opencode-local")
```

`mcp__c2c__list` showed `opencode-local` as `alive:false` with `pid=2901589` (later `2915146` after a prior partial refresh), even though a live managed session was running (`run-opencode-inst-outer` pid 2734574, inner opencode node pid 2734575).

## Root cause

Managed clients (opencode-local, kimi-nova, codex-local, etc.) run under a persistent outer restart loop. Between iterations the child PID dies and a new one is spawned. The broker registry retains the old PID until something updates it. When the old PID is reaped, `broker_registration_is_alive` returns false, so direct alias-based sends are rejected, even though the agent is functionally alive in a new process.

This is the same class as `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`.

## Fix applied

Ran `python3 c2c_refresh_peer.py opencode-local --pid 2734575` to point the registry at the live inner opencode process:

```json
{
  "alias": "opencode-local",
  "status": "updated",
  "old_pid": 2915146,
  "new_pid": 2734575,
  "new_pid_start_time": 28715942
}
```

After refresh, `mcp__c2c__send(from_alias="kimi-nova", to_alias="opencode-local", ...)` succeeded:

```json
{"queued":true,"ts":1776083488.475051,"to_alias":"opencode-local"}
```

## Remaining risk

The refresh is manual. Any managed session that restarts will drift stale again until an operator (or automation) notices and runs `refresh-peer`. A durable fix would be one of:

1. **Auto-refresh on child restart**: the outer loop updates the broker registry with the new PID before handing control to the child.
2. **Session-token liveness**: replace PID-based liveness with a session-scoped heartbeat token that survives restarts.
3. **Dead-letter redelivery**: the broker already recovers swept messages on re-registration with the same `session_id`, but that only helps if the session is swept and then re-registers; it does not help if the session is merely marked `alive:false` while still registered.

For now, the operational workaround is: when a direct send to a managed alias fails with "recipient is not alive", check `pgrep -a -f run-<client>-inst-outer`, then run `c2c refresh-peer <alias> --pid <live-pid>`.
