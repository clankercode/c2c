# Code-Health Audit — task #388 — second pass — 2026-04-28T10:12Z

Pure investigation. Builds on the 07:55Z first-pass audit
(`2026-04-28T07-55-00Z-coordinator1-code-health-audit.md`). Goal:
non-overlapping findings, ≤1-day fixes, severity LOW–MED.

The first pass framed the four giants (c2c.ml 9089 / c2c_mcp.ml 5956
/ relay.ml 4806 / c2c_start.ml 4578) and proposed 10 structural
splits. This pass focuses on **micro-duplication**, **test-coverage
cliffs**, **naming drift**, and **mli/dead-code hygiene** —
orthogonal slices a single agent can land in 2-6 hours each.

## Scope checks done

- All `.ml` files under `ocaml/` (38650 non-test LoC + ~15700 test
  LoC).
- Only 7 `.mli` files exist in the entire tree — interface hygiene
  is structurally weak (separate finding below).

---

## Top 5 actionable findings

### 1. **`read_file` / `write_file` / `with_temp_dir` reimplemented ≥18×** — LOW, 3-4h

- **Pattern** (greps):
  - 16 distinct `let mkdir_p` / `let mkdir_p_mode` definitions
  - 6 distinct `let read_file` (incl. `read_file_trimmed`)
  - 6 distinct `let write_file`
  - 5 distinct `let with_temp_dir`
- **Representative call sites**:
  - `ocaml/cli/c2c.ml:3480` `read_file_trimmed`
  - `ocaml/cli/c2c.ml:7539` `read_file`
  - `ocaml/cli/c2c_memory.ml:70-79` `read_file` + `write_file`
  - `ocaml/cli/c2c_stats.ml:291-296` `read_file` + `write_file`
  - `ocaml/c2c_mcp.ml:5513` `read_file` (inside `handle_tool_call`)
  - `ocaml/cli/c2c_relay_managed.ml:32` `mkdir_p`
  - `ocaml/cli/c2c_migrate.ml:121` `mkdir_p`
  - `ocaml/cli/c2c_setup.ml:214` `mkdir_p dry_run dir` (variant
    signature — the only one that takes a dry-run flag)
  - test fixtures: `cli/test_c2c_stats.ml:32`,
    `cli/test_c2c_onboarding.ml:36`,
    `cli/test_c2c_migrate.ml:30-36`, `test/test_relay_nudge.ml:17`,
    `cli/test_c2c_memory.ml:11`, `test/test_c2c_mcp.ml:3014`,
    `test/test_c2c_start.ml:1865`, `test/test_post_compact_hook.ml:44`
- **Note**: a partial helper exists at
  `ocaml/cli/c2c_utils.ml:11` (`let mkdir_p = C2c_mcp.mkdir_p`) and
  `c2c_utils.ml:35` (`atomic_write_json`) — but is not used by
  most call sites.
- **Fix shape**: extend `C2c_utils` (or a new `C2c_io` module) with
  `read_file`, `read_file_trimmed`, `write_file`,
  `atomic_write_file`, `with_temp_dir` (production + test-fixture
  variants share an impl). One sweep replaces the duplicates;
  `c2c_setup.ml`'s dry-run variant becomes
  `C2c_io.mkdir_p ~dry_run`.
- **Risk**: LOW. Pure mechanical refactor; all variants share the
  same posix semantics.
- **Estimate**: 3-4h including build + review-and-fix.
- **Builds on first-pass #5/#6/#9** but is more concrete (those
  proposed `C2c_env`/`C2c_pid`/`C2c_paths`; this is `C2c_io`).

### 2. **`jsonrpc_error` cloned 3× verbatim** — LOW, 1h

- **Sites** (identical bodies, all building the same JSON-RPC
  error envelope):
  - `ocaml/server/c2c_mcp_server_inner.ml:149`
  - `ocaml/c2c_mcp.ml:246`
  - `ocaml/cli/c2c.ml:5267` (locally-bound inside the embedded MCP
    loop)
- **Fix shape**: hoist to `C2c_jsonrpc.error ~id ~code ~message` (or
  reuse the `c2c_mcp.ml` definition — already at top level there).
  `c2c_mcp_server_inner.ml` and `c2c.ml`'s embedded server delete
  their copies and call through.
- **Risk**: LOW. Pure dedupe; no behaviour change.
- **Estimate**: 1h. Could ride along with first-pass #7 (Yojson
  helpers) but is self-contained enough to land alone.

### 3. **ISO-8601 timestamp formatting reinvented 13×** — LOW, 2h

- **Sites** (each builds its own `Printf.sprintf
  "%04d-%02d-%02dT%02d:%02d:%02dZ"` over `Unix.gmtime`):
  - `ocaml/relay_enc.ml:40`
  - `ocaml/relay_signed_ops.ml:14`
  - `ocaml/relay_identity.ml:53`
  - `ocaml/cli/c2c_stickers.ml:85`
  - `ocaml/cli/c2c.ml:68, 5788, 7253, 8474`
  - `ocaml/cli/c2c_stats.ml:534` (hour-truncated variant)
  - `ocaml/server/c2c_mcp_server_inner.ml:50` (millisecond variant)
  - `ocaml/tools/c2c_inbox_hook.ml:29` (millisecond variant)
  - `ocaml/tools/c2c_cold_boot_hook.ml:14`
  - `ocaml/tools/c2c_post_compact_hook.ml:46`
- **Variants**: 3 precisions (second / millisecond / hour). Most
  use seconds; `c2c_inbox_hook`, `mcp_server_inner`, and
  `c2c.ml:8474` use milliseconds.
- **Fix shape**: `C2c_time.iso8601_utc : ?precision:[`S | `Ms | `H]
  -> float -> string` plus `now_iso ()`. Replace 13 call sites; bug
  surface (e.g. wrong format on `tm_year + 1900`) becomes
  impossible to recur.
- **Risk**: LOW. Pure formatting; tests already pin the formats
  indirectly via archive parsing.
- **Estimate**: 2h.
- **Distinct from first-pass #5/#7** (env/JSON helpers).

### 4. **Test-coverage cliffs: 5 modules >300 LoC with zero direct tests** — MED, sized per-module

Bottom 5 by `LoC / test_LoC` (excluding `c2c.ml` which the first
pass already flagged for splitting):

| Module | LoC | Direct test file | Severity |
|---|---:|---|---|
| `ocaml/cli/c2c_setup.ml` | 1358 | none | high — it owns `c2c install <client>` for all 5 clients |
| `ocaml/cli/c2c_agent.ml` | 967 | none | high — eph-agent lifecycle, role-rendering |
| `ocaml/cli/c2c_rooms.ml` | 650 | none | medium — rooms are part of north-star group goal |
| `ocaml/cli/c2c_peer_pass.ml` | 560 | none | medium — security-relevant signing |
| `ocaml/cli/c2c_docs_drift.ml` | 416 | none | low — internal tool |

`server/c2c_mcp_server_inner.ml` (361) and `c2c_wire_bridge.ml`
(297) are also untested but are thin wrappers; lower priority.

- **Fix shape per module**: a 30-60 min smoke-test slice per file —
  not full coverage, just one happy-path invocation per public
  entrypoint. Pattern in `cli/test_c2c_migrate.ml` is a good
  template (fixture-gated, env-driven). `c2c_setup.ml` and
  `c2c_peer_pass.ml` are the ones where a future regression has
  swarm-wide blast radius — prioritize those two.
- **Risk**: LOW (tests only). Build risk only.
- **Estimate**: 4-6h for the top 2; defer the rest until a relevant
  slice touches them.
- **Distinct from first-pass** which did not enumerate the
  zero-test modules.

### 5. **`.mli` files exist for only 7 modules out of 60+** — MED, ongoing

- **Present**: `relay_identity.mli`, `relay_signed_ops.mli`,
  `c2c_capability.mli`, `c2c_start.mli`, `c2c_role.mli`,
  `c2c_mcp.mli`, `cli/c2c_stickers.mli`.
- **Missing for**: `relay.ml` (4806 LoC, no `.mli`), `c2c.ml`
  (9089), `c2c_relay_connector.ml` (800), `c2c_setup.ml` (1358),
  `c2c_agent.ml` (967), `c2c_worktree.ml` (904), `c2c_stats.ml`
  (709), `c2c_rooms.ml` (650), `c2c_memory.ml` (577),
  `c2c_peer_pass.ml` (560), `c2c_wire_bridge.ml` (297),
  `tools/*.ml`. Implication: every top-level `let` is implicitly
  exported; "what is the contract of this module" requires reading
  the whole file.
- **Fix shape**: do NOT generate all of them — that's a half-day
  per module. Instead, **add `.mli` opportunistically as part of
  any first-pass extraction slice** (e.g. when first-pass #1 splits
  `Broker` out of `c2c_mcp.ml`, the new `c2c_broker.ml` ships with
  `c2c_broker.mli`). Set the convention: any new `.ml` file ≥200
  LoC ships with an `.mli`. The two highest-value retroactive
  ones: `c2c_setup.ml` (install matrix is the user-facing contract)
  and `c2c_peer_pass.ml` (security surface).
- **Risk**: LOW. `.mli` is opt-in tightening; if signatures drift,
  build catches it.
- **Estimate**: 1-2h per module, but **distribute across slices**;
  not its own slice. As a slice-blocking convention it's free.

---

## Naming consistency — minor noise, not worth a slice

Checked `session_id` vs `sid`, `alias` vs `name`, `room_id` vs
`room_name`. Findings:

- **`sid` as alias for `session_id`**: only 4 hits in `c2c_mcp.ml`,
  9 in `c2c_start.ml`. Local-binding shorthand inside narrow
  scopes; not actually two parallel names for the same field.
  **No action.**
- **`name` vs `alias`**: legitimately distinct concepts —
  `name` = managed-instance name (per `c2c start -n`); `alias` =
  c2c routing identity. Conflated in conversation but the code
  keeps them apart. **No action.**
- **`room_id` vs `room_name`**: `room_id` is canonical (~550 hits);
  `room_name` appears 4× in `c2c_mcp.ml:2685-2727` only, and they
  are local plurals (`room_names`) for a list-render. **No
  action.**

---

## Dead-code spot check

- `let _ = ...` bindings: 12 across non-test files; all 8 in
  `c2c.ml` look intentional (suppressed unused warnings on
  thread/fd handles). **No action.**
- `TODO`/`FIXME`/`XXX`/`HACK` comments: only 3 across non-test.
  Code is comment-clean.

---

## Headline

The single highest-leverage micro-slice is **finding #1**
(`C2c_io` consolidation — 18 helper duplicates). Pairs naturally
with first-pass #5 (`C2c_env`), #6 (`C2c_pid`), #9 (`C2c_paths`)
into a "swarm-utilities batch" that, taken together, removes
~600-800 LoC of scattered boilerplate and gives the 2026-Q3 swarm
one obvious place to look for "is there already a helper for X?"

If only one slice gets picked up: do #1 first; #2 (jsonrpc_error)
is a 1-hour drive-by that any agent can ride alongside another
slice.
