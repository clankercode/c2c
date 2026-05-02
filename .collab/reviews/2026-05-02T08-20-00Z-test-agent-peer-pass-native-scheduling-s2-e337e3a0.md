# Peer-PASS: native scheduling S2 (e337e3a0)

**reviewer**: test-agent
**commit**: e337e3a0d41e34cf11f9b9bc00d755964e5aaef4
**author**: stanza-coder
**review scope**: 1 commit, 4 files, +147/-69
**parent**: 598c9d2b (S1 fix — quote escaping, root dedup, docs/tier, gitignore)
**chain-slice base**: slice/native-scheduling-s1 (598c9d2b)
**build**: `just build` in main tree → exit 0 (warnings only)

## Verdict: PASS

---

## Diff Review (c2c_mcp.mli)

**Additions** — `schedule_entry` type exported (9 fields: s_name, s_interval_s, s_align, s_message, s_only_when_idle, s_idle_threshold_s, s_enabled, s_created_at, s_updated_at), plus `unescape_toml_string`, `strip_quotes`, `parse_schedule`.

Correct: type signature matches the OCaml `type schedule_entry = { ... }` definition in c2c_mcp_helpers.ml. `unescape_toml_string` and `strip_quotes` are the same pure string-transforming functions from the S1 fix — appropriate to expose in mli since CLI code needs them too. `parse_schedule: string -> schedule_entry` is a pure parser.

---

## Diff Review (c2c_mcp_helpers.ml)

**Additions** — `schedule_entry` type (identical copy of CLI's former type), `unescape_toml_string`, `strip_quotes`, `parse_schedule` moved here from `c2c_schedule.ml`.

`parse_schedule` implementation: splits on `\n`, filters `[`, `#` lines, extracts key=value pairs via `String.index_opt`, finds fields with `List.assoc_opt` and `float_of_string`/`bool_of_string` with defaults. String values go through `strip_quotes` → `unescape_toml_string`.

**Correctness checks:**
- Empty string check on `read_file_opt` content before parsing — avoids parsing empty/invalid files as zero-entry entries
- `s_name = ""` check in `schedule_dir_managed_heartbeats` filters unparseable entries
- Float parsing wrapped in try/catch — malformed values fall through to defaults
- Bool parsing is simple `= "true"` — TOML booleans are lowercase, matches S1's write path
- Files sorted before parsing — deterministic ordering

---

## Diff Review (c2c_start.ml)

**`managed_heartbeat_of_schedule_entry`**: converts a `schedule_entry` to a `managed_heartbeat`.

- `schedule` field: if `s_align <> ""`, calls `parse_heartbeat_schedule e.s_align` (same parser used elsewhere). On parse error, falls back to `Interval e.s_interval_s`. If `s_align` is empty, uses `Interval e.s_interval_s` directly.
- All other managed_heartbeat fields set appropriately: `command = None`, `command_timeout_s = 30.0`, `clients = []` (all clients except codex-headless per comment), `role_classes = []`, `idle_only = e.s_only_when_idle`, `idle_threshold_s = e.s_idle_threshold_s`.

**`schedule_dir_managed_heartbeats`**: reads `.toml` files from `C2c_mcp.schedule_base_dir alias`.

- `Sys.readdir dir` → `Array.to_list` → filter `String.length n > 5 && String.sub n (String.length n - 5) 5 = ".toml"`
- `List.sort String.compare` — deterministic
- `List.filter_map` with `C2c_io.read_file_opt` + empty-string guard + `s_name = ""` guard
- Both `Sys_error` and `Unix.Unix_error` caught → returns `[]` (missing dir or permission errors fall through silently)
- Returns `managed_heartbeat list`

**Startup wiring**: `schedule_specs = schedule_dir_managed_heartbeats ~alias:effective_alias` then `per_agent_specs:(per_agent_managed_heartbeats ~name @ schedule_specs)`. Append order gives schedule_specs highest merge priority (they come after per_agent_heartbeats, which have high priority per design doc). This matches the stated design intent.

---

## Diff Review (c2c_schedule.ml)

Type changed to `type schedule_entry = C2c_mcp.schedule_entry` — GADT-style type sharing, not a copy. `parse_schedule` changed to `= C2c_mcp.parse_schedule`. All the parsing code removed from CLI and lives in the library now.

`unescape_toml_string` and `strip_quotes` removed from CLI (now only in helpers). The `render_schedule` and `escape_toml_string` remain in CLI (S1 fix, correctly applied on write path).

**Note**: `unescape_toml_string` is still needed in `c2c_mcp_helpers.ml` for reading. It exists in exactly one place now (helpers). `escape_toml_string` exists in CLI only (writing). No duplication.

---

## Cross-Cut Concerns

- **No external deps added** — pure OCaml stdlib
- **`C2C_SCHEDULE_ROOT_OVERRIDE` env var** honored by `schedule_root` (in helpers, called via `schedule_base_dir`) — test hook preserved
- **Error handling**: `Sys_error`, `Unix.Unix_error`, and empty/parse-fail all return empty list — startup won't crash on missing or corrupt schedule files
- **Sort order**: files sorted before parsing — stable ordering
- **Type sharing**: GADT-style `type x = C2c_mcp.x` — OCaml shares representation, no runtime overhead

---

## Test Coverage

Stanza reports 32 tests pass. I cannot run tests in the worktree (dune not in PATH there), but `just build` in main tree passes. The S1 fix (598c9d2b) and S2 commit (e337e3a0) together represent the complete scheduling feature.

---

## Summary

S2 correctly wires S1's TOML storage into the startup heartbeat path. The `schedule_entry` type and parser live in the library (single source of truth), CLI re-exports via type sharing, `c2c_start.ml` reads `.c2c/schedules/<alias>/` at startup and appends entries to `per_agent_specs`. Error handling is defensive. No external deps. Build clean.
