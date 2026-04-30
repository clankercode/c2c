# SPEC: #562 deliver-inbox daemon log persistence

## Background / Bug
During the #488 forensic dive, PTY misdelivery was suspected but broker.log was clean (broker innocent). The deliver-inbox daemon had no persisted logs — the forensic trail was lost. We need the daemon to emit structured audit events so future incidents are traceable.

## What This Slice Does

### Core (MUST — 150-200 LoC)
Add a structured `deliver-inbox.log` sidecar file in the broker root, written by the daemon (not the broker), containing per-message lifecycle events. Format mirrors `log_broker_event` conventions: JSONL, best-effort append, ts + event discriminator + fields.

**Log file path**: `<broker_root>/deliver-inbox.log`
**Permissions**: 0o600 (same as broker.log — contains session message content)
**Rotation**: None in this slice (deferred to #61)

**Event catalog:**

| event | When | Fields |
|-------|------|--------|
| `deliver_inbox_drain` | After `poll_once_generic` drains N messages from inbox | `session_id`, `client`, `count`, `drained_by` |
| `deliver_inbox_kimi` | After `poll_once_kimi` returns | `session_id`, `alias`, `count`, `ok` |
| `deliver_inbox_no_session` | `poll_once_generic` called with unknown session_id | `session_id`, `error` |

**Implementation**: New internal module `c2c_deliver_inbox_log.ml` in `ocaml/cli/` — thin structured logger exposing `log_drain`, `log_kimi`, `log_no_session`. The daemon calls these after each poll iteration. No broker code changed for core.

### Stretch (ORTHOGONAL — ~30 LoC)
Add `drained_by_pid` field to the `deliver_inbox_drain` broker.log event emitted from the daemon side, so cross-correlation between daemon log and broker.log works without parsing two log files. This is purely additive — the daemon already has the PID from `start_daemon`.

**Additional field on `deliver_inbox_drain` broker.log event**: `"drained_by_pid": <int>`

No broker.ml changes required — the daemon itself emits the extra field by passing its PID to the logger.

## What This Slice Does NOT Do
- No PTY injection logging (that's a separate surface in `c2c_start.ml` / `c2c_wire_bridge.ml`)
- No changes to `c2c_broker.ml` `drain_inbox` / `append_archive`
- No rotation logic
- No changes to `c2c_mcp.mli` public API

## Files Changed
```
ocaml/cli/c2c_deliver_inbox_log.ml  (NEW — internal logger module)
ocaml/cli/c2c_deliver_inbox.ml      (instrument poll_once_generic + poll_once_kimi + single-shot path)
ocaml/cli/dune                      (add c2c_deliver_inbox_log.ml to c2c_deliver_inbox executable)
```

## Test Plan
- Unit test: `log_broker_event` conventions (JSONL, ts field, best-effort)
- The existing 169 tests must continue to pass (no broker behavior change)
- Smoke: run `c2c-deliver-inbox --help` and verify no crash

## Dependencies
- None beyond existing OCaml dependencies
- Uses `Yojson.Safe`, `C2c_io.append_jsonl`, `Unix.gettimeofday` — all already in scope

## Sizing
~150-200 LoC core, ~30 LoC stretch, ~60-90 min
