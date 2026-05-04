# Alias Hijack: Explicit register Tool Had No Guard Against Evicting Live Peers

**Agent:** storm-beacon
**Date:** 2026-04-14T04:00Z
**Severity:** MEDIUM — could silently evict a live agent's alias, routing all future DMs to the wrong inbox
**Status:** CLOSED — fix was self-contained (shipped at time of filing, 2026-04-14). `alias_hijack_conflict` guard added to `register` handler in `c2c_mcp.ml`. Two tests: `test_tools_call_register_rejects_alias_hijack` + `test_tools_call_register_allows_own_alias_refresh`. M2/M3/M4 mitigations (permission/question alias-hijack) confirmed done per todo-ongoing.txt.

## Symptom

`c2c list` showed `opencode-c2c-msg / storm-beacon` (dead PID) in the registry instead of
`d16034fc / storm-beacon` (live, the actual storm-beacon session). Any DM to `storm-beacon`
was routed to `opencode-c2c-msg.inbox.json` (wrong file); the actual session's inbox was
never written to.

## Root Cause

The `register` MCP tool previously had NO guard against evicting an alive peer:

```ocaml
(* OLD: always evict — no liveness check *)
Broker.register broker ~session_id ~alias ~pid ~pid_start_time;
```

The `auto_register_startup` function (called at MCP server startup) has `alias_occupied_guard`
that prevents ONE-SHOT probes from evicting live peers. But the explicit `register` tool
call bypassed this guard entirely — allowing any session to claim any alias regardless of
whether the current holder is alive.

If an OpenCode session running in the c2c-msg directory (with session_id `opencode-c2c-msg`)
called `mcp__c2c__register {alias: "storm-beacon"}`, it would evict the live storm-beacon
registration silently. All future `send` calls to `storm-beacon` would queue to
`opencode-c2c-msg.inbox.json` instead of the real Claude session's inbox.

## Fix

Added `alias_hijack_conflict` guard to the `register` handler in `ocaml/c2c_mcp.ml`:

```ocaml
let alias_hijack_conflict =
  List.find_opt
    (fun reg ->
      reg.alias = alias
      && reg.session_id <> session_id
      && Broker.registration_is_alive reg)
    (Broker.list_registrations broker)
in
match alias_hijack_conflict with
| Some conflict ->
    Lwt.return (tool_result ~is_error:true
      ~content:(Printf.sprintf
        "register rejected: alias '%s' is currently held by an alive session '%s'. 
         Options: (1) use a different alias, (2) wait for the current holder to exit,
         (3) call list to see all registrations."
        alias conflict.session_id))
| None ->
    Broker.register broker ...
```

An agent re-registering its **own** alias (same session_id) is always allowed — this covers
the normal "PID refresh after restart" case. Only a DIFFERENT session trying to claim an
occupied alias is rejected.

2 new OCaml tests: `test_tools_call_register_rejects_alias_hijack` and
`test_tools_call_register_allows_own_alias_refresh`. 101 OCaml tests total.

## Error Message Design

Per Max's guidance, error messages guide to the correct path:
```
register rejected: alias 'storm-beacon' is currently held by alive session 'opencode-c2c-msg'.
Options: (1) use a different alias — call register with {"alias":"<new-name>"},
(2) wait for the current holder's process to exit (it will release automatically),
(3) call list to see all current registrations and their liveness.
```

## Related

- `.collab/findings/2026-04-14T03-30-00Z-storm-beacon-session-id-drift-refresh-peer-bug.md`
  (session_id drift via refresh-peer + Guard 2 race — different root cause, same symptom)
- `auto_register_startup` has `alias_occupied_guard` (startup path); this fix adds the
  equivalent guard to the explicit `register` tool call path.
