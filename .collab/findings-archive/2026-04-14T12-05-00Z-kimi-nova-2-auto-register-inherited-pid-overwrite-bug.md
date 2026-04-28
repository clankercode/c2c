---
alias: kimi-nova-2
timestamp: 2026-04-14T12:05:00Z
severity: high
status: fixed
---

# auto_register_startup can overwrite alive registration with inherited wrong PID

## Symptom

`kimi-nova-2` (session_id=`kimi-nova`) is correctly registered in the broker with
pid=748416 — the live Kimi Wire daemon (`c2c_kimi_wire_bridge.py --loop`).

However, the current Kimi session was launched from inside a Codex session and
inherited `C2C_MCP_CLIENT_PID=552302` (Codex's outer-loop PID). If
`auto_register_startup` fires now (e.g. on broker reconnect or MCP tool call),
it will overwrite the Wire daemon's PID (748416) with Codex's PID (552302).

This breaks Kimi's liveness tracking: if the Wire daemon later dies, the broker
will still think `kimi-nova-2` is alive because Codex's PID is alive.

## Root cause

`auto_register_startup` has `hijack_guard` (prevents same-session-different-alias)
and `alias_occupied_guard` (prevents same-alias-different-session-different-pid),
but it does NOT guard against:

- same session_id + same alias + existing registration is ALIVE + new PID differs

The `Broker.register` function updates the existing entry in-place for same-session
re-registrations, so the wrong PID silently clobbers the correct one.

## Reproduction

```bash
# In a Codex session (pid 552302)
$ export C2C_MCP_AUTO_REGISTER_ALIAS=kimi-nova-2
$ export C2C_MCP_SESSION_ID=kimi-nova
$ kimi --mcp-config-file ...
# Inside Kimi, C2C_MCP_CLIENT_PID inherited as 552302
# Call mcp__c2c__register or trigger auto_register_startup
# Result: registry entry for kimi-nova changes pid 748416 -> 552302
```

## Recommended fix

Add a `same_session_alive_different_pid` guard to `auto_register_startup`:

```ocaml
let same_session_alive_different_pid =
  List.exists
    (fun reg ->
       reg.session_id = session_id
       && reg.alias = alias
       && Broker.registration_is_alive reg
       && reg.pid <> pid)
    existing
in
if not hijack_guard && not alias_occupied_guard && not same_session_alive_different_pid then ...
```

This allows legitimate restarts (old PID is dead) while blocking inherited-wrong-PID
overwrites (old PID is alive).

## Impact

High — any child CLI launched from another agent can inherit a wrong
`C2C_MCP_CLIENT_PID` and silently corrupt the broker's liveness data for the
child's session.
