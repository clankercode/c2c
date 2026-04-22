# jungel-coder (two-Ls) MCP Registration Bug - Root Cause Found

**Date**: 2026-04-22
**Agent**: jungel-coder, galaxy-coder
**Status**: Root cause identified

## Registry State

```
alias=jungle-coder  session_id=6e45bbe8-998c-4140-b77e-c6f117e6ca4b  pid=424242  alive=None
alias=jungel-coder session_id=jungle-coder                            pid=None    alive=None
```

## Root Cause: hijack_guard triggered

The `auto_register_startup` function in `c2c_mcp.ml` has a `hijack_guard` that checks:

```ocaml
(* Guard 1: if an alive registration already exists for this session_id
   with a DIFFERENT alias, skip — prevents session hijack *)
let hijack_guard =
  List.exists
    (fun reg ->
      reg.session_id = session_id
      && reg.alias <> alias
      && Broker.registration_is_alive reg)
    existing
```

For the two-Ls instance trying to auto-register:
- `session_id = "jungle-coder"` (from C2C_MCP_SESSION_ID)
- `alias = "jungle-coder"` (from C2C_MCP_AUTO_REGISTER_ALIAS)

The one-L instance has:
- `session_id = "jungle-coder"` (coincidentally same as two-Ls alias!)
- `alias = "jungel-coder"` (one L, different from two-Ls alias)

`registration_is_alive` treats `alive=None` as "alive" (legacy compat). So:
- `reg.session_id = "jungle-coder" = session_id` ✓
- `reg.alias = "jungel-coder" <> "jungle-coder" = alias` ✓
- `registration_is_alive reg = true` ✓

`hijack_guard = True` → registration silently skipped!

## Why this happened

The one-L instance's session_id happened to be set to "jungle-coder" (which coincidentally matches the two-Ls instance's desired alias). This is a naming collision that triggered the hijack guard.

## Fix Options

1. **Kill the one-L instance first**: Stop the one-L instance (jungel-coder), wait for its registration to expire/be cleared, then start the two-Ls instance. Then restart the one-L instance.

2. **Change the two-Ls instance's session_id**: Give it a different session_id so it doesn't collide with the one-L instance's session_id.

3. **Clear stale registration**: Manually remove the one-L instance's registration from registry.json, then restart the two-Ls instance.

## Note

This is NOT a bug in the code — the hijack_guard is working correctly. The collision is due to coincidental naming between two different agents.
