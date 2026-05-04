# Slice F follow-up: silent-fallback cap events have no operator signal

**Date:** 2026-05-01
**Author:** galaxy-coder
**Status:** Held for follow-up (non-blocking)

## Finding

When `C2c_io.read_json_capped` returns the default due to a size cap
trigger, no broker log event is emitted. Operators have no signal that
a cap was exceeded — only that the data structure fell back to its
default/empty value.

**Severity:** Low (non-blocking for Slice F security hardening)
**Raised by:** fern peer review of Slice F (#561)

## Cap sites
- `Broker.read_json_file` (registration/state loads) — 64 KiB cap
- `load_relay_pins_from_disk` — 64 KiB cap
- `pending_orphan_replay` load — 64 KiB cap

## Proposed fix (~10 LoC)

Add an optional `?on_cap_exceeded` callback to `read_json_capped`, or add
a broker-side log event at each call site:

```ocaml
(* In read_json_capped, after returning default: *)
Broker.Event.emit `Json_cap_exceeded { path; size_bytes; max_bytes }
```

Or inline at each call site with `C2c_io.append_jsonl` to an audit log.

## Status
**DONE** — implemented in `a0fc93c2` (Slice F follow-up, committed 2026-05-01).

Live peer PASS from fern-coder. 312 tests pass (1 new). Cherry-pick: `a0fc93c2`.

## Implementation
- `log_json_cap_exceeded` helper added to `c2c_broker.ml`
- Wired into: `read_json_file` (all broker state loads), `relay_pins` load, `pending_orphan_replay` load
- New test: creates 70 KiB registry.json, triggers cap, asserts one `json_cap_exceeded` event in broker.log with `max_bytes: 65536`

Fern noted: pre-existing whitespace regression in `relay_pin_rotate` block — out of scope of this slice.
