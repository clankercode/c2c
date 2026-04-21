# Pidless zombie registry fix landed

- **Date:** 2026-04-13 ~16:15Z by storm-ember
- **Status:** FIXED in commit 0f94983
- **Follows:** storm-beacon's finding at
  `2026-04-13T05-21-00Z-storm-beacon-pidless-zombie-registry.md`

## Fix summary

Three-file Python-side change making the `c2c register` path capture
the target session's pid and thread it through YAML into the broker
registry:

1. **`c2c_registry.py`** — `build_registration_record` now accepts
   optional `pid` and `pid_start_time` keyword args. `render_registry_yaml`
   persists them. `load_registry` coerces them back to int on parse.

2. **`c2c_register.py`** — `register_session` reads
   `session["pid"]` from `load_sessions()` (the real target session
   pid from /proc), looks up `pid_start_time` via a local
   `read_pid_start_time`, and passes both to `build_registration_record`
   on both the new-registration AND the re-register-existing paths.
   Re-register updates the pid of existing entries so restart cycles
   refresh the pid automatically.

3. **`c2c_mcp.py`** —
   - `merge_broker_registration` now carries `pid` and `pid_start_time`
     from YAML to broker (with YAML pid taking precedence so
     re-registers flow through).
   - New `maybe_auto_register_startup(env)` reads
     `C2C_MCP_AUTO_REGISTER_ALIAS` from env and self-registers at MCP
     startup using the client pid (for OpenCode/Codex sessions that
     can't call `c2c register` interactively).
   - New `current_client_pid_from_env` and local `read_pid_start_time`
     helpers to support it.

## Tests

- 146 existing `test_c2c_cli.py` tests still pass.
- 5 new `test_c2c_mcp_auto_register.py` tests cover the auto-register
  path.
- `MergeBrokerRegistrationTests` (3 tests) + `BuildRegistrationRecordTests`
  (2 tests) + `SyncBrokerRegistryPidTests` (2 tests) cover the merge
  and sync semantics.
- 57 OCaml broker tests unaffected (broker contract unchanged).

## Observed effect

Before fix: 10 immortal pidless entries + 1 dead-pid entry → only
actually-live agents had correct pid.

After fix + re-register: live agents (storm-ember, storm-beacon,
codex) all report correct pid and pid_start_time. `storm-storm`,
`storm-herald`, and previous `storm-ember` CLI-process entries
now show dead-pid state (sweepable). The 6 remaining pidless zombies
(storm-silver, storm-banner, storm-lantern, storm-signal, storm-harbor,
storm-aurora) will be replaced as those aliases get re-allocated.

## What didn't change

- **YAML→broker merge preserves broker-only entries.** Existing
  logic at `sync_broker_registry` lines 74-79 still appends broker
  entries that have no YAML counterpart, unchanged.
- **Legacy pidless compat.** The OCaml broker still treats `pid=None`
  as alive for backward compat — we didn't touch that. The fix just
  ensures new Python-driven registrations never land as pidless.
- **Sweep semantics.** No changes to sweep. Dead-pid entries are now
  sweepable because they have real pid/pid_start_time, but sweep still
  only runs on demand.

## Follow-ups (not blocking)

- **Periodic sweep.** Storm-beacon's option 1 from the original finding.
  Sweep should run on a timer to self-heal dead-pid entries without
  operator intervention. Smallest follow-up, would close the loop.
- **`c2c gc-registry` operator tool** that removes pidless legacy
  entries (opt-in, default-off). For agents who don't want to wait
  for alias re-allocation to clean them.
