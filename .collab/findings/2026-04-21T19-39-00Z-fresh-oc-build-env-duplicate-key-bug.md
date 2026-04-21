---
author: fresh-oc (planner1)
ts: 2026-04-21T19:39:00Z
severity: high
status: fixed in 0648a87
---

# build_env Duplicate-Key Bug — Managed Instances Couldn't Register

## Symptom

`c2c start opencode -n cold-boot-test` launched the instance, but the instance
never appeared in `c2c list`. Room joins worked (swarm-lounge join events fired),
but no registry entry. `c2c send cold-boot-test "..."` returned "unknown alias".

## Root Cause

`build_env` in `ocaml/c2c_start.ml` had a buggy fold_left-based in-place replacement.
When updating an existing env key (e.g. C2C_MCP_SESSION_ID), the match arm used
`:: acc` (the outer fold accumulator — the FULL remaining list) instead of the
tail of the walked sublist:

```ocaml
| (k', v') :: _ when k' = k -> (k, Printf.sprintf "%s=%s" k v) :: acc
```

Result: both the old value AND the new value appeared in the child's env array:
```
C2C_MCP_SESSION_ID=planner1       ← inherited from parent Claude Code session
C2C_MCP_AUTO_REGISTER_ALIAS=planner1
C2C_MCP_SESSION_ID=cold-boot-test2   ← intended value
C2C_MCP_AUTO_REGISTER_ALIAS=cold-boot-test2
```

The broker MCP server uses the FIRST occurrence of `C2C_MCP_SESSION_ID` at startup,
registering as `planner1` (the parent session, already dead). The child never got
its intended alias registered.

## Fix (0648a87)

Replaced buggy fold with filter-then-append: strip all overridden keys from the
inherited env, then append the authoritative values at the end. No duplicates possible:

```ocaml
let filtered = Array.to_list (Unix.environment ())
  |> List.filter (fun e -> not (List.mem (env_key e) override_keys))
let new_entries = List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) additions in
Array.of_list (filtered @ new_entries)
```

## Verification

After fix, `cold-boot-test2` env shows:
```
C2C_MCP_SESSION_ID=cold-boot-test2
C2C_MCP_AUTO_REGISTER_ALIAS=cold-boot-test2
```
Instance registered correctly, messages delivered via promptAsync. 

## Why It Wasn't Caught Earlier

Previous managed instances (coordinator1, oc-sitrep-demo) were launched BEFORE this
Claude Code session started (planner1). So their parent process didn't have
C2C_MCP_SESSION_ID set — no duplicate. Only instances launched FROM an already-managed
session experienced the bug (nested launches during this session's work).
