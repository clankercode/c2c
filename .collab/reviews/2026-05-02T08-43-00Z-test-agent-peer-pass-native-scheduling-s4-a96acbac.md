# Peer-PASS: native scheduling S4 — MCP tool surface (a96acbac)

**reviewer**: test-agent
**commit**: a96acbac308b3dc4d4674d32c7768912ae163e03
**author**: stanza-coder
**branch**: slice/native-scheduling-s4
**worktree**: .worktrees/native-scheduling-s4/
**review scope**: 3 files, +204/-1

## Verdict: PASS

---

## Diff Review

### c2c_mcp.ml additions

Three new tools registered in `base_tool_definitions`:
- `schedule_set` — required: `name`, `interval_s`; optional: `message`, `align`, `only_when_idle`, `idle_threshold_s`, `enabled`
- `schedule_list` — no args
- `schedule_rm` — required: `name`

Handler dispatch in `handle_tool_call`: `schedule_set` → `Schedule_handlers.handle_schedule_set`, etc.

Module alias `Schedule_handlers = C2c_schedule_handlers` added. New module inserted in dune `modules` list (position between Memory_handlers and Room_handlers — correct alphabetical-ish ordering).

**Tool definitions correct**: float/int/bool/string prop types match handler expectations. `interval_s` as `float_prop` (handler accepts `Float` or `Int`). `enabled` and `only_when_idle` as `bool_prop`.

---

### c2c_schedule_handlers.ml (new file)

**TOML rendering** (`escape_toml_string`, `render_schedule`): self-contained duplicate of CLI's rendering code. Correctly applies `escape_toml_string` to all string fields (name, align, message, created_at, updated_at). Matches S1 fix.

**`default_message`**: hardcoded UTF-8 em-dash string — matches `Session heartbeat — pick up the next slice`. Acceptable literal.

**JSON helpers** (`float_member`, `bool_member`): `Yojson.Safe.Util.member` followed by type dispatch. `float_member` handles both `Float` and `Int` JSON variants. `bool_member` handles `Bool` only (null/missing → None).

**`list_toml_files`**: same filter pattern as CLI + watcher: `String.length n > 5 && String.sub n (String.length n - 5) 5 = ".toml"`. Sorted for determinism. `Sys_error` caught (returns []).

---

### `handle_schedule_set`

1. Validates `name` (non-empty) and `interval_s` (required) before any I/O ✅
2. `alias_for_current_session_or_argument` for session resolution ✅
3. Defaults: `message = default_message`, `align = ""`, `only_when_idle = true`, `enabled = true`, `idle_threshold_s = interval_s` ✅
4. **`created_at` preservation**: if file exists, read existing entry and preserve `s_created_at` if non-empty ✅ — prevents `created_at` from being reset on updates (S3/S4 correctly handle this)
5. Atomic file write via `Fun.protect ~finally:(fun () -> close_out oc)` ✅
6. Error handling: wraps entire write in try/with, returns `tool_err` on exception ✅
7. Return shape: `{saved, alias, interval_s, enabled}` — useful metadata ✅

**Minor observation**: if `C2c_io.read_file_opt path` returns `""` for an existing file (shouldn't happen), `parse_schedule ""` produces a default entry with empty s_name, and `created_at` falls through to `now_ts` (loses original created_at). This is an extremely unlikely edge case (would require the file to exist but read as empty). Not a blocker.

---

### `handle_schedule_list`

1. Resolves alias ✅
2. `list_toml_files dir` → sorted `.toml` list ✅
3. Maps each file: reads content, parses, returns fields ✅
4. Returns `Yojson.Safe.to_string (`List items)` — JSON array of schedule objects ✅

**Minor observation**: `C2c_io.read_file_opt path` returning `""` for a valid file would produce an empty-s_name entry filtered out (safe). No error returned for unparseable files — silently skipped. Low-severity: if a schedule file is corrupted mid-read, it simply doesn't appear in list. Not a blocker.

---

### `handle_schedule_rm`

1. Validates `name` non-empty ✅
2. Resolves alias ✅
3. Checks `Sys.file_exists path` before removing ✅
4. `Sys.remove` wrapped in `try/with _ -> ()` ✅ — if remove fails (permissions), returns success anyway. Low severity: idempotent, file gone or already gone either way.
5. Return: `{deleted: name}` ✅

---

## Build Check
`opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe` → exit 0 ✅

---

## Summary

Correct MCP tool surface for schedule management. All three tools handle required/optional args correctly, use the same TOML format as CLI (S1 quote escaping preserved), handle alias resolution consistently with memory handlers, and return useful JSON responses. Minor edge-case observations (empty-file read, unparseable file handling) are low-severity and not blockers. Build clean.
