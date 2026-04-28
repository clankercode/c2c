# Code-Health Audit — coordinator1 — 2026-04-28T07:55Z

Pure-investigation pass. No bug-fix scope; only navigability /
duplication / naming / dead-code / boundary / convention concerns.
Severity LOW–MED throughout (refactor, not defect).

## Top files by size (ocaml/, .ml only, non-test)

| Lines | Path |
|------:|------|
| 8979 | ocaml/cli/c2c.ml |
| 5864 | ocaml/c2c_mcp.ml |
| 4806 | ocaml/relay.ml |
| 4578 | ocaml/c2c_start.ml |
| 1358 | ocaml/cli/c2c_setup.ml |

(Tests omitted — `test_c2c_mcp.ml` is 7959 LOC / 228 cases; valid
candidate for a separate slice but tests-only.)

Prior audits in `.collab/findings/` and `.collab/research/` cover
papercuts, MCP schemas, dead-letter, doc drift, alias pool, peer-pass
security, MCP tool schema, and rooms — none target structural
refactor of the four giants. So this report is non-overlapping with
prior work.

---

## Ranked candidates

### 1. Split `Broker` submodule out of `c2c_mcp.ml`  — MED
- **File**: `ocaml/c2c_mcp.ml:303-2983` (`module Broker = struct … end`)
- **Proposal**: extract to `ocaml/c2c_broker.ml` (or
  `ocaml/broker/broker.ml`). 2681 LOC, 173 inner `let`s, owns
  registrations, leases, pid liveness, rooms, pending-permissions,
  message-archive. Stable interface — already addressed via
  `Broker.t`, so the surface is well-defined. After extraction
  `c2c_mcp.ml` shrinks to ~3200 LOC of dispatch + tool definitions.
- **LoC delta**: ~0 net, redistribution. New `.mli` ~150 LOC.
- **Pre-reqs**: none. Watch for inner-state access from outside the
  module (spot-check shows access is already through accessor
  functions — clean). Test build: `dune build` only.

### 2. Split `handle_tool_call` dispatcher in `c2c_mcp.ml`  — MED
- **File**: `ocaml/c2c_mcp.ml:3933-5794` (1861 LOC, single function).
- **Proposal**: per-tool handlers extracted into a
  `Tool_handlers` module — one `handle_send`, `handle_register`,
  `handle_join_room`, … each 30-150 LOC. Dispatcher reduces to a
  lookup + arg-decode boilerplate. Mirrors the
  `tool_definitions`/`base_tool_definitions` split already present
  at line 3176.
- **LoC delta**: ~0; navigability win.
- **Pre-reqs**: candidate #1 (Broker split) clarifies what each
  handler closes over.

### 3. Move embedded HTML/JS landing pages out of `relay.ml`  — MED
- **File**: `ocaml/relay.ml` ~lines 2700-3900 (large multiline
  string literals with embedded JS for the relay status page,
  pairing flow, etc.).
- **Proposal**: extract assets to `ocaml/relay/assets/*.html.in`
  and load via `[%blob …]` (already used elsewhere — see
  `role_designer_embedded.ml`). Keeps OCaml source navigable;
  HTML/JS gets editor syntax highlighting; diffs no longer churn
  the relay file.
- **LoC delta**: -800 from relay.ml; +800 to assets dir; net 0.
- **Pre-reqs**: confirm dune supports the embed pattern in this
  build (it does for `role_designer_embedded.ml`).

### 4. Split `c2c.ml` into per-command-group files  — MED
- **File**: `ocaml/cli/c2c.ml` (8979 LOC, 88 `*_cmd` defs).
- **Proposal**: most groups already extracted (`C2c_coord`,
  `C2c_rooms`, `C2c_memory`, `C2c_peer_pass`, `C2c_worktree`,
  `C2c_stickers`, `C2c_sitrep`). Remaining bulk: `relay_*` (~1100
  LoC, 3360-4429), `health`/`status`/`verify` block (~700 LoC,
  1221-2050), `sweep`/`migrate-broker` (~150 LoC, 837-1175). Move
  to `cli/c2c_relay.ml`, `cli/c2c_health.ml`, `cli/c2c_admin.ml`.
  Final `c2c.ml` ≤ 5000 LoC: registration helpers + dispatcher.
- **LoC delta**: ~0 redistribution.
- **Pre-reqs**: none; this is the most mechanical of the splits.

### 5. Centralise env-var access in a typed `Env` module  — MED
- **Pattern**: 152 occurrences of `Sys.getenv_opt`, ~70 distinct
  `C2C_*` names parsed inline with bespoke
  `match … Some "1" -> true` boilerplate. Same key (e.g.
  `C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_AUTO_JOIN_ROOMS`,
  `C2C_INSTANCE_NAME`) read in 3+ files with subtly different
  fallback rules.
- **Proposal**: `ocaml/c2c_env.ml` exposing `auto_register_alias :
  unit -> string option`, `auto_join_rooms : unit -> string list`,
  `cli_force : unit -> bool`, etc. Each call-site becomes a single
  function; semantic drift between sites becomes impossible.
  Doubles as a single source of truth for `c2c doctor env` style
  diagnostics.
- **LoC delta**: -200 to -400 net (deduping fallback logic).
- **Pre-reqs**: none. Worth doing alongside any future env-var
  documentation slice — CLAUDE.md already enumerates ~12 of these.

### 6. Extract pid-liveness helpers  — LOW
- **Pattern**: `Unix.kill pid 0`, `/proc/<pid>/cwd` scans, and pid
  start-time compare logic appear in `c2c_mcp.ml` (Broker,
  registrations), `cli/c2c_worktree.ml` (cwd_holders),
  `c2c_wire_daemon.ml`, `cli/c2c_agent.ml`. Each implements its
  own variant.
- **Proposal**: `ocaml/c2c_pid.ml` with `is_alive : int -> bool`,
  `is_alive_with_starttime : pid:int -> starttime:int64 -> bool`,
  `cwd_holders : path:string -> int list`. Replaces ~5
  reimplementations. Aligns with `c2c worktree gc` heuristic
  documented in CLAUDE.md.
- **LoC delta**: -100 to -150 net.
- **Pre-reqs**: candidate #1 useful first (Broker calls account for
  most of the duplication).

### 7. Extract Yojson construction helpers  — LOW
- **Pattern**: 290 `` `Assoc [ … ] `` literals, many constructing
  the same shapes (e.g. tool-result envelopes, MCP error objects,
  message envelopes). `tool_result`, `prop`, `bool_prop` already
  live at `c2c_mcp.ml:239-258` — extend the pattern.
- **Proposal**: `ocaml/c2c_json.ml` with `obj : (string * Yojson.Safe.t)
  list -> Yojson.Safe.t`, `opt_field`, `string_list_field`, plus
  the existing helpers re-exported. Rooms and memory tools
  benefit most.
- **LoC delta**: -80 to -150.
- **Pre-reqs**: none, but coordinate with #2 (handler split).

### 8. Tame `try … with _ -> ()` swallowing  — LOW
- **Pattern**: 220 occurrences. Some are intentional (best-effort
  cleanup), but the blanket `_` swallows `Sys.Break` and bugs.
- **Proposal**: introduce `Best_effort.run : (unit -> unit) -> unit`
  (catches `Unix_error`, `Sys_error`, `End_of_file`; re-raises
  `Sys.Break`/`Out_of_memory`). Migrate gradually — start with
  `c2c_mcp.ml` and `c2c_start.ml`. Any site that genuinely needs
  catch-all keeps the bare form with a `(* CATCH-ALL OK: ... *)`
  comment.
- **LoC delta**: ~0; correctness/observability win.
- **Pre-reqs**: none. Could be a 1-hour drive-by during another
  slice rather than its own.

### 9. Hoist `instances_dir_base` and `~/.local/...` paths  — LOW
- **Files**: `ocaml/cli/c2c.ml:813`,
  `ocaml/cli/c2c_relay_managed.ml:30` — same
  `~/.local/share/c2c/instances` literal computed independently.
  Other path literals (`~/.local/bin/c2c` in test_agent_refine.ml)
  are scattered too.
- **Proposal**: a `C2c_paths` module: `instances_dir`,
  `c2c_binary`, `xdg_state_root`, `broker_root` (the latter
  already exists in `C2c_utils`). One file owns "where things
  live."
- **LoC delta**: -30; one place to change for XDG transitions.
- **Pre-reqs**: none.

### 10. Split `c2c_start.ml` heartbeat helpers  — LOW
- **File**: `ocaml/c2c_start.ml` (4578 LOC). Lines ~159-465 are a
  self-contained heartbeat scheduling subsystem (parse_*,
  enqueue_*, render_*, start_managed_heartbeat,
  start_codex_heartbeat). Naming staleness: some functions named
  `default_managed_heartbeat_content` are no longer "default"
  (push-aware variant exists alongside).
- **Proposal**: extract to `ocaml/c2c_heartbeat.ml`. Rename
  `default_managed_heartbeat_content` → `legacy_heartbeat_content`
  to reflect actual role. Tests already exist
  (`test_c2c_start.ml`); migrate the heartbeat-scoped ones with
  the module.
- **LoC delta**: ~0; clarity.
- **Pre-reqs**: none.

---

## Out-of-scope but noted

- `test/test_c2c_mcp.ml` (7959 LOC, 228 cases) — split by tool
  family (rooms, memory, send/poll, register). Not in this report
  because tests can be split cheaply any time.
- 138 top-level `let _ = ...` blocks — usually intentional but
  worth a sweep alongside #8.
- No `dune build` was run (parallel softlock risk per task brief);
  any actual extraction slice must include a clean build before
  peer-PASS.

## Headline (top 3)

1. **Split Broker submodule** out of c2c_mcp.ml (#1) — biggest single
   navigability win; unlocks #2 and #6.
2. **Per-command-group split of c2c.ml** (#4) — mechanical, safe,
   cuts the largest file ~45%.
3. **Centralise env-var access** in `C2c_env` (#5) — touches the
   widest surface area; doubles as a documented contract for the
   ~70 `C2C_*` knobs the swarm tunes daily.
