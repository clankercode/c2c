# Peer-PASS: kimi wire-bridge cleanup (3c0df1cc)

**reviewer**: test-agent
**commit**: 3c0df1cc4b6f7ee96d3dd2eff97a20160fcc8db3
**author**: stanza-coder
**branch**: slice/kimi-wire-bridge-cleanup
**scope**: 24 files, +102/-750 (cleanup of deprecated kimi wire-bridge)

## Verdict: PASS

---

## Summary

Removes deprecated kimi wire-bridge code (deprecated in Slice 1, replaced by `C2c_kimi_notifier` in Slice 2). 750 lines removed across OCaml code, tests, and docs.

**Dead code removed:**
- `c2c_wire_daemon.ml` — entirely deleted (daemon lifecycle management for kimi wire)
- kimi-specific JSON-RPC wire client, `run_once_live`, `drain_to_spool`, `build_mcp_config` from `c2c_wire_bridge.ml`
- `Kimi_wire` variant from `c2c_capability.ml/.mli`
- `needs_wire_daemon` from `CLIENT_ADAPTER` signature, all client configs, and `c2c_start.mli`
- `start_wire_daemon` and `wire_bridge_script_path` from `c2c_start.ml`
- 7 wire-daemon CLI subcommands from `c2c.ml` (start/stop/status/list/format-prompt/spool-write/spool-read)

**Functions retained in `c2c_wire_bridge.ml`:** `format_envelope`, `format_prompt`, `spool_of_path`, `spool_read`, `spool_write` — confirmed via grep to be used by:
- `c2c_start.ml` (format_prompt)
- `c2c.ml` (spool_of_path, spool_read, spool_write — monitor drain path)
- `test_wire_bridge.ml` (all retained functions)
- `test_c2c_oc_plugin.ml` (spool functions)

**Key correctness checks:**
- `KimiAdapter.probe_capabilities` returns `[]` ✅ — kimi no longer advertises a wire capability
- `delivery_mode "kimi"` → `"notifier"` ✅ — kimi delivery path updated
- `KimiAdapter.delivery_mode` in `c2c_start.ml` removed `Kimi_wire` from probed capability check ✅
- `c2c_kimi_wake_daemon.py` deprecation message updated to reference notifier ✅
- `c2c_wire_bridge.ml` docstring updated to reflect retained functions ✅
- `test_wire_bridge.ml` description updated ✅
- All `wire_pid` references removed from `run_outer_loop` ✅
- `wire_daemon_group` removed from `all_cmds` list ✅

**Doc changes verified:** wire-bridge references updated to notification-store push across CLAUDE.md, SPEC-delivery-latency.md, kimi-notification-store-delivery.md, communication-tiers.md, client-delivery.md, MSG_IO_METHODS.md, MIGRATION_STATUS.md, NOTES.md, active-goal.md.

---

## Build
`opam exec -- dune build ./ocaml/cli/c2c.exe ./ocaml/server/c2c_mcp_server.exe` → exit 0 ✅
