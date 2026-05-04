# Broker: simultaneous registration causes "cannot send a message to yourself"

**Date:** 2026-05-03
**Filed by:** jungle-coder
**Severity:** MEDIUM
**Status:** Closed — fix landed 4e3d6180 (coordinator1, 2026-05-03)

---

## Symptom

Two pytest tests fail consistently with:
```
error: cannot send a message to yourself (heal-bob-1777738511)
```

- `docker-tests/test_ephemeral_contract.py::TestEphemeralContract::test_ephemeral_not_in_history`
- `docker-tests/test_broker_respawn_pid.py::TestBrokerRespawnPid::test_respawn_alias_still_receives`

Both tests use `session_id == alias` (e.g., `heal-alice-{TS}` for both fields).

## Root Cause (suspected)

**Location:** `ocaml/c2c_mcp_helpers_post_broker.ml` — `alias_for_current_session_or_argument`

```ocaml
let alias_for_current_session_or_argument ?session_id_override broker arguments =
  match current_registered_alias ?session_id_override broker with
  | Some alias -> Some alias      (* ← uses session_id to look up alias *)
  | None ->
      (match optional_string_member "from_alias" arguments with
       | Some a -> Some a
       | None -> optional_string_member "alias" arguments)
```

**`current_registered_alias`** (same file, line ~1085):
```ocaml
let current_registered_alias ?session_id_override broker =
  let session_id = Option.value session_id_override ~default:(current_session_id ()) in
  broker.registrations
  |> RegistrationMap.iter
  |> (fun f -> f (fun reg -> reg.session_id = session_id))
  |> Option.map (fun reg -> reg.alias)
```

The send guard in `ocaml/c2c_send_handlers.ml:271`:
```ocaml
if from_alias = to_alias then
  Lwt.return (tool_err "error: cannot send a message to yourself")
```

**The bug path:**
1. Alice registers with `session_id=alice-TS, alias=alice-TS`
2. Bob registers with `session_id=bob-TS, alias=bob-TS` (concurrently or immediately after)
3. Alice calls `send bob-TS "msg"` with `session_id_override=alice-TS`
4. `alias_for_current_session_or_argument` resolves `from_alias` via `current_registered_alias alice-TS` → correctly gets `alice-TS`
5. BUT: something in the concurrent registration path causes the broker to bind Alice's session to Bob's alias, making `from_alias` resolve to `bob-TS` (same as `to_alias`)
6. Guard fires: "cannot send a message to yourself (bob-TS)"

**Most likely root cause:** The `send_alias_impersonation_check` (line 257-269) checks whether `from_alias` is held by a different live session. When two registrations happen simultaneously with identical `session_id` values (due to timestamp collision), the broker's registration map may be updated in a way that causes cross-talk between sessions.

## How to Reproduce

```bash
C2C_CLI=/home/xertrov/.local/bin/c2c python3 -m pytest \
  docker-tests/test_broker_respawn_pid.py -v
# → 1 failed, 1 passed
# FAILED: test_respawn_alias_still_receives
```

## What's Needed

1. **Worktree + slice** — fix the registration binding in `c2c_broker.ml`
2. **Add regression test** — test that `session_id == alias` registration doesn't cause cross-talk
3. **Verify** — re-run both failing tests after fix

## Files to Inspect

- `ocaml/c2c_broker.ml:1832` — `register` function
- `ocaml/c2c_broker.ml` — `registrations` map data structure and locking
- `ocaml/c2c_mcp_helpers_post_broker.ml:1085-1094` — `current_registered_alias` + `alias_for_current_session_or_argument`
- `ocaml/c2c_send_handlers.ml:271-272` — self-send guard (correct, but fires on wrong `from_alias`)
