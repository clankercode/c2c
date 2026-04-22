# Python vs OCaml Gap Analysis

**Date:** 2026-04-23
**Author:** CEO
**Status:** COMPLETE

## Method

1. Grepped all `c2c_*.py` files referenced from OCaml CLI (`ocaml/cli/c2c.ml`,
   `ocaml/c2c_start.ml`, `ocaml/c2c_poker.ml`), scripts/, and CLAUDE.md.
2. Distinguished OCaml binary (primary entry, `~/.local/bin/c2c`) from legacy
   Python shim (`c2c_cli.py`, NOT in PATH as `c2c`).
3. For each Python file, determined: is it called by the OCaml binary at
   runtime? Or only by the legacy Python CLI?

---

## Load-Bearing Python Scripts (called by OCaml binary at runtime)

### 1. `c2c_relay_connector.py`

| Field | Value |
|-------|-------|
| **Called by** | OCaml `c2c relay connect` (c2c.ml:3427) |
| **Role** | Polling relay connector: registers aliases, forwards outbound messages, pulls remote→local messages, sends heartbeats |
| **OCaml equiv** | `Relay.Relay_client` exists (HTTP client) but polling loop + lease management is Python-only |
| **Verdict** | **PORT to OCaml** |
| **Effort** | Medium — HTTP client exists; need to port the polling loop, state machine, and identity signing |

### 2. `c2c_relay_rooms.py`

| Field | Value |
|-------|-------|
| **Called by** | OCaml `c2c relay rooms invite/uninvite/set-visibility` (was fallback; now native OCaml) |
| **Role** | Room invite/uninvite/set-visibility operations |
| **OCaml equiv** | All subcommands (list/join/leave/send/history/invite/uninvite/set-visibility) now native OCaml |
| **Verdict** | **DONE — 5dc11c8 ports all 3 remaining subcommands to Relay_client** |
| **Effort** | N/A |

### 3. `c2c_setcap.py`

| Field | Value |
|-------|-------|
| **Called by** | OCaml `c2c setcap` (c2c.ml:4215) |
| **Role** | Grants `CAP_SYS_PTRACE=ep` to the c2c Python interpreter for PTY injection |
| **OCaml equiv** | None — POSIX capabilities require `setcap` utility + kernel support |
| **Verdict** | **KEEP-PYTHON** |
| **Effort** | N/A — cannot port to OCaml |

### 4. `c2c_mcp.py`

| Field | Value |
|-------|-------|
| **Called by** | `c2c start kimi` — OCaml generates Kimi MCP config pointing to `c2c_mcp.py` (c2c_start.ml:856-872) |
| **Role** | Bootstrapper: syncs registry, sets env vars, auto-registers, checks if OCaml binary is fresh, builds if stale, then execs it |
| **OCaml equiv** | None — OCaml binary doesn't do self-build-check |
| **Verdict** | **KEEP-PYTHON** (non-trivial: registry sync + fresh-build detection can't be shell-replaced) |
| **Effort** | N/A |

### 5. `c2c_deliver_inbox.py`

| Field | Value |
|-------|-------|
| **Called by** | OCaml `c2c_start.ml` as fallback when `c2c-deliver-inbox` OCaml binary not found (c2c_start.ml:1021) |
| **Role** | Delivery daemon: watches inbox via inotifywait, delivers messages |
| **OCaml equiv** | OCaml `c2c-deliver-inbox` binary (installed via `just install-all`). Fallback only fires when binary is missing. |
| **Verdict** | **DEPRECATED — delete after confirming OCaml binary is always installed** |
| **Effort** | Trivial — delete 1 file, confirm no callers |

### 6. `c2c_poker.py`

| Field | Value |
|-------|-------|
| **Called by** | OCaml `C2c_poker.start` as fallback when `resolve_poker_script_path` finds it (c2c_poker.ml:17) |
| **Role** | PTY heartbeat poker — keeps sessions awake between tool calls |
| **OCaml equiv** | `C2c_poker.start` is the primary path; Python fallback only fires when broker_root has the script |
| **Verdict** | **DEPRECATED — delete after confirming OCaml poker is always used** |
| **Effort** | Trivial — delete 1 file, confirm no callers |

---

## Dead Code — Delete

| File | Evidence |
|------|----------|
| `c2c_kimi_wire_bridge.py` | `wire_bridge_script_path` defined (c2c_start.ml:1063) but **never called**. OCaml `C2c_wire_daemon.start_daemon` is the only caller. |
| `c2c_claude_wake_daemon.py` | Listed in c2c.ml:1324 as deprecated wake daemon; OCaml never calls it. |
| `c2c_pts_inject.py` | DEPRECATED marker; imported only by deprecated `c2c_deliver_inbox.py`. |
| `c2c_wire_daemon.py` | OCaml `wire-daemon` group (c2c.ml:7969) is the primary; Python version superseded. OCaml binary is `c2c` in PATH, so Python never reached. |

---

## Operator Tools — Keep Python (not runtime load-bearing)

| File | Role |
|------|------|
| `c2c_sitrep.py` | Manual sitrep creation, called by coordinator1 role |
| `c2c_smoke_test.py` | Manual broker smoke test; OCaml has native `c2c smoke-test` |
| `c2c_restart_me.py` | Legacy Python CLI only (`c2c restart-me`); OCaml has `c2c restart-self` (different semantics) |

---

## Migration Priority Order

| Priority | Script | Verdict | Effort | Status |
|----------|--------|---------|--------|--------|
| 1 | `c2c_relay_rooms.py` (3 subcommands) | PORT to OCaml | Low | ✅ Done `5dc11c8` |
| 2 | `c2c_mcp.py` | REPLACE with shell script | Low | Pending |
| 3 | `c2c_deliver_inbox.py` | KEEP (live Python CLI dispatch + tests) | N/A | No action |
| 4 | `c2c_poker.py` | KEEP (OCaml spawns it, c2c_deliver_inbox imports it) | N/A | No action |
| 5 | `c2c_kimi_wire_bridge.py` | DEPRECATED (dead code, but imported by c2c_wire_daemon.py) | Trivial | ✅ Done `3370052` |
| 6 | `c2c_claude_wake_daemon.py` | Already in deprecated/ | Done | No action needed |
| 7 | `c2c_pts_inject.py` | KEEP (imported by live c2c_deliver_inbox.py) | N/A | No action |
| 8 | `c2c_wire_daemon.py` | KEEP (live Python CLI wire-daemon dispatch + tests) | N/A | No action |
| 9 | `c2c_relay_connector.py` | PORT to OCaml | Medium | ✅ Done `78c65ad` + `e0cb42b` |
| 10 | `c2c_setcap.py` | KEEP-PYTHON | N/A | No action |

### Post-port follow-up improvements (non-blocking)

These are minor gaps identified after the core port was verified complete:

| Item | Description | Priority |
|------|-------------|----------|
| F1 | Signal handling in OCaml run loop (graceful SIGTERM/SIGINT) — Python has this | Medium |
| F2 | TLS/CA bundle support (`--ca-bundle` arg) for corporate proxies | Low |
| F3 | `node_id` derivation: hostname+git-hash (matches Python) vs current "unknown-node" fallback | Low |

---

## Notes

- **OCaml binary is primary entry point** (`~/.local/bin/c2c` = OCaml). Python `c2c_cli.py` is legacy shim (NOT in PATH as `c2c`). It still has live dispatch to Python modules for wire-daemon, deliver-inbox, and relay subcommands.
- **`c2c start <client>`** uses OCaml native for all clients. Python fallbacks only fire when OCaml binaries/scripts are missing from repo.
- **Python CLI still live**: The Python `c2c_cli.py` dispatch has callers (OCaml c2c_start.ml spawns Python CLI for some operations, c2c_health.py imports Python modules). Many Python scripts are "load-bearing" for the Python CLI even if not for the OCaml binary.
- **Truly dead code confirmed**: Only `c2c_kimi_wire_bridge.py` (never called from OCaml, only imported by Python wire_daemon). Added DEPRECATION marker; keep until Python CLI is retired.
- **Configure scripts** (`c2c_configure_*.py`) not analyzed — these are operator setup tools, not runtime messaging infrastructure.
