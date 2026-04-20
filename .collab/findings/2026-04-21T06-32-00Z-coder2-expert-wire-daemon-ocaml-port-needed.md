---
author: coder2-expert
ts: 2026-04-21T06:32:00Z
severity: medium
status: open — task logged, not yet started
---

# Wire Daemon OCaml Port Needed

## Problem

`c2c wire-daemon` is the current recommended Kimi delivery path (docs/known-issues.md,
CLAUDE.md), but it lives entirely in Python (`c2c_wire_daemon.py` +
`c2c_kimi_wire_bridge.py`). The OCaml binary has no `wire-daemon` subcommand.

## Impact

Anyone using `c2c wire-daemon start` gets "unknown command" from the OCaml binary.
Workaround: `python3 c2c_wire_daemon.py start` — but this is undiscoverable.

## Required OCaml Port Scope

1. `kimi --wire` JSON-RPC client (newline-delimited JSON-RPC 2.0 over stdio)
   - `initialize` request
   - `prompt` request (deliver message)
2. Crash-safe spool (write messages before Wire prompt, clear after ACK)
   - Path: `<broker-root>/../kimi-wire/<session-id>.spool.json`
3. Daemon lifecycle with pidfiles in `~/.local/share/c2c/wire-daemons/<session-id>/`
   - Subcommands: start / stop / status / list
4. Poll loop: inbox drain → format c2c envelope → Wire `prompt`
5. Cross-impl tests: OCaml vs Python produce equivalent behavior for same input

## Python Reference

- `c2c_kimi_wire_bridge.py`: Wire client, spool, deliver_once, run_once_live
- `c2c_wire_daemon.py`: daemon lifecycle (start_daemon, stop_daemon, list_daemons)
- Format: `format_c2c_envelope()` wraps messages in `<c2c event="message" ...>` XML
- Spool: read/write/append/clear around a JSON file

## Suggested Approach

New `ocaml/c2c_wire_daemon.ml` module + `c2c wire-daemon` subcommand group in CLI.
Cross-impl parity test: feed same broker inbox state to both Python and OCaml,
assert identical `kimi --wire` prompt payloads.

## Related

- `c2c start kimi` (c2c_start.ml:42) still uses `needs_deliver=true` → PTY notify daemon
  for managed sessions. After OCaml port, switch kimi to use wire-daemon instead.
- Max request: "We'll need an OCaml port of that then. Ideally some cross-impl testing."
