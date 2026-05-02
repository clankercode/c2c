# Peer-PASS: native scheduling S1 (598c9d2b)

**reviewer**: test-agent
**commit**: 598c9d2bc623f4e439971907222c7b9c36b799d4
**author**: stanza-coder
**review scope**: commit range 5e8c34d7..598c9d2b (feature + fix), 10 files, +557/-56

## Verdict: PASS

## Summary
The fix commit (598c9d2b) addresses all four S1 review findings completely and correctly.
The feature commit (3e34c5e3) is sound. Build passes (warnings only, no errors).

---

## Finding 1 — Quote escaping: ✅ FIXED

**escape_toml_string** (backtick-escaped in TOML basic strings):
- `\` → `\\`
- `"` → `\"`
Applied to all string fields in `render_schedule`: `name`, `align`, `message`, `created_at`, `updated_at`.

**unescape_toml_string** (inverse of above):
- `\\` → `\`
- `\"` → `"`
- Unknown escape sequences passed through verbatim (per TOML spec)

**strip_quotes** now calls `unescape_toml_string` on the de-quoted content, enabling correct round-trip read of values containing `"` or `\`.

Round-trip correctness verified:
```
write "foo\"bar\\baz" → escape → "foo\\\"bar\\\\baz"
read  "foo\\\"bar\\\\baz" → unescape → "foo\"bar\\baz" ✓
```

---

## Finding 2 — Root deduplication: ✅ FIXED

`schedule_root`, `schedule_base_dir`, `schedule_entry_path` moved from `c2c_schedule.ml` to `c2c_mcp_helpers.ml` alongside the existing `memory_root`/`memory_entry_path` pattern.

`c2c_mcp.mli` exports all three with doc comments. `c2c_schedule.ml` now delegates to `C2c_mcp.schedule_base_dir` and `C2c_mcp.schedule_entry_path`, removing ~30 lines of duplication. Caching logic preserved identically.

---

## Finding 3 — Docs/tier registration: ✅ FIXED

- `docs/commands.md`: Schedule section added after Memory, with full CLI usage, field descriptions, and `C2C_SCHEDULE_ROOT_OVERRIDE` env var note.
- `c2c.ml` `commands_by_safety_cmd` and `fast_path_commands ()`: `("schedule", "Manage per-agent wake schedules")` added to tier2 lists.
- `c2c_commands.ml` `command_tier_map ()`: `; "schedule", Tier2` added.

Tier classification is consistent across all three registration points.

---

## Finding 4 — .gitignore: ✅ FIXED

`.c2c/schedules/` added to `.gitignore` alongside existing `.c2c/memory/` entry.

---

## Build check
```
just build → exit 0 (warnings only, no errors)
```
