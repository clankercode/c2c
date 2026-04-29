# Code-health audit #3 — 2026-04-29

**Author**: willow-coder
**Scope**: OCaml tree — parallel-canonical patterns, `failwith` on user-facing paths,
Yojson.Safe usage, module sizes.
**Method**: subagent-driven parallel sweep + `scripts/audit-staleness-check.sh` staleness pass.
Read-only; no code modified.

---

## Prior audit findings: status check

| Finding | Status | Cross-link |
|---|---|---|
| `mkdir_p` → `C2c_io.mkdir_p` | ✅ LANDED (a350be59) | #400b |
| `open_out_gen` broker.log → `C2c_io.append_jsonl` | ✅ LANDED (7a3b4dd0) | #388 |
| `c2c_mcp.ml` memory handlers deduplication | IN FLIGHT (stanza owns #338 design) | `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md` §2 |

---

## Findings

### Finding 1 — `Yojson.Safe.from_file` / `Yojson.Safe.from_string`: canonical helper gap

**Severity**: MED

**Status**: IN FRAME — `C2c_io` lacks a `read_json_opt` helper

The `#388` dedup pass converged `open_out_gen` and `mkdir_p`, but the JSON read side has the same scattering problem. The pattern:

```ocaml
try Yojson.Safe.from_string (C2c_io.read_file path) with _ -> default
```

appears 15+ times across `cli/c2c.ml` alone. `json_util.from_file_opt` exists (`try Some (Yojson.Safe.from_file path) with _ -> None`) but is underutilized — `c2c_mcp.ml:1154` (`load_relay_pins_from_disk`) hand-rolls the same pattern instead of using it.

The most useful canonical addition to `C2c_io`:

```ocaml
(** [read_json_opt ?perm path] — read + parse JSON, [None] on any error.
    Combines [read_file_opt] (best-effort I/O) with [Yojson.Safe.from_string]
    (best-effort parse). For callers that want [None] on missing/unparseable files. *)
let read_json_opt ?(perm = 0o600) path =
  match read_file_opt path with
  | "" -> None
  | s ->
    try Some (Yojson.Safe.from_string s) with _ -> None
```

**Candidates already using `json_util.from_file_opt`** (no change needed):
- `relay_nudge.ml:47` ✅ wrapped in outer try/catch, correct behavior
- `c2c_mcp.ml:564` (`read_json_file ~default`) — already a good abstraction
- `c2c_mcp.ml:1154` — could use `json_util.from_file_opt` + `Option.value ~default:`\`Assoc []`

**Candidates NOT wrapped** (could raise):
- `c2c_mcp.ml:3813` — post-filter assumption, pre-guarded, LOW risk
- `cli/c2c.ml:8763,8791` — bare `Yojson.Safe.from_string` at lines 8763/8791
- `c2c_start.ml:1285,2005,2994`
- `c2c_relay_connector.ml:81,139,216`
- `cli/c2c_stickers.ml:81,263,519`

**Proposed slice**: Add `C2c_io.read_json_opt` (~10 LOC) + migrate the 3 most-risk bare sites in `c2c_start.ml` and `c2c_relay_connector.ml`. The CLI sticker sites are lower risk (CLI startup, not hot path). Est: ~30 LOC.

---

### Finding 2 — `failwith` on CONFIG paths: graceful-degrade opportunity

**Severity**: MED

**Status**: IN FRAME

Four production `failwith` calls that fire on user misconfiguration and should degrade gracefully (return `Error` / `None`) rather than crash the broker:

| File | Line | Message | Classification |
|---|---|---|---|
| `c2c_mcp.ml` | 1379 | `Relay_identity.save` failure | CONFIG (disk/permissions) |
| `c2c_mcp.ml` | 1402 | SSH pubkey file unparseable | CONFIG (corrupt key file) |
| `c2c_mcp.ml` | 1596 | `C2C_IN_DOCKER=1` without `C2C_MCP_BROKER_ROOT` | CONFIG (user env) |
| `c2c_stickers.ml` | 11 | Not in a git repository | CONFIG (user context) |

The `relay.ml` SQLite `failwith`s (20+ sites) are correctly INTERNAL — SQLite failure means DB corruption or programming error, crash is appropriate.

The `c2c_wire_bridge.ml:169` `failwith` on JSON-RPC error response is PROTOCOL — a peer's rejection should be propagated as a result, not raised.

**Note**: `relay_identity.ml:111` (`failwith "relay_identity.sign: invalid private key seed"`) is INTERNAL — programming error, not user-facing.

**Proposed slice**: Convert the 4 CONFIG `failwith`s to return `Result`/`option` types. `c2c_stickers.ml:11` is the cleanest win — `Result` return is idiomatic OCaml for "this operation requires git". Est: ~20 LOC.

---

### Finding 3 — `c2c_mcp.ml` 7500+ LOC: `handle_tool_call` extraction

**Severity**: MED

**Status**: IN FRAME — documented in prior audits

`handle_tool_call` spans ~2000 LOC (5538–~7500) with 25+ match arms. Prior audit (stanza, 2026-04-29) already identified this and recommended extraction per-handler. Not repeating the detail here — link to `.collab/research/2026-04-29-stanza-coder-c2c-mcp-code-health.md` §1.

**Proposed slice**: Extract the 3 memory handlers (`memory_list`, `memory_read`, `memory_write`) as a first win — ~340 LOC, mechanical extraction, follows the #338 design phase that's already in flight. Est: 2 h.

---

### Finding 4 — `auto_register_impl` guard logging: 4x duplication

**Severity**: LOW

**Status**: IN FRAME — noted in prior audit

Four nearly identical guard-logging blocks at `c2c_mcp.ml:5302–5317` — each differs only in the predicate and fields logged. ~40 LOC of mechanical duplication. Prior audit (cairn, 2026-04-29) also flagged this.

**Proposed slice**: Extract a `log_guard_reg ~label reg` helper. Est: ~15 LOC net reduction. LOW priority — not blocking anything.

---

### Finding 5 — `memory_base_dir` / `memory_entry_path` cross-file duplication

**Severity**: LOW-MED

**Status**: IN FRAME — code comments acknowledge the duplication

Identical functions in `c2c_mcp.ml:361–385` and `cli/c2c_memory.ml:49–68`. The `c2c_mcp.ml` even has comments at lines 7271, 7362, 7446 saying "lifted top-level (audit §2)" — but the duplication was never removed.

**Proposed slice**: Keep one definition (in `c2c_memory.ml` since it's the CLI module), delete the copy from `c2c_mcp.ml`. Est: ~25 LOC net reduction + eliminates the stale comments.

---

## Summary table

| # | Severity | Finding | Est. LOC | Priority |
|---|---|---|---|---|
| 1 | MED | `C2c_io` needs `read_json_opt` + migrate bare `Yojson.Safe.from_file` sites | ~30 | Medium |
| 2 | MED | 4 CONFIG `failwith` → graceful `Result` return | ~20 | Medium |
| 3 | MED | `handle_tool_call` extraction (follow stanza's #338) | ~0 (refactor only) | Low-Medium |
| 4 | LOW | `auto_register_impl` guard-logging 4x duplication | ~15 net | Low |
| 5 | LOW-MED | `memory_base_dir`/`memory_entry_path` cross-file duplication | ~25 net | Low |

**Total net LOC reduction potential**: ~90 LOC across 5 findings.

---

## Not findings (preserved as-is, documented for audit completeness)

| Site | Reason preserved |
|---|---|
| `c2c_mcp.ml:568` (`open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_text]`) | Atomic-replace write-to-tmp+rename, not append |
| `c2c_mcp.ml:1382` (`open_out_gen [Open_append; Open_creat] 0o644`) | World-readable SSH authorized_keys-style file, intentionally public |
| `c2c_mcp.ml:2372` (`open_out_gen` DM archive append) | DM archive append, not broker.log target |
| `c2c_mcp.ml:2788` (`open_out_gen` dead-letter append) | Dead-letter append, not broker.log target |
| `c2c_mcp.ml:3081` (`open_out_gen` atomic truncate) | Atomic-replace write-to-tmp+rename |
| `c2c_mcp.ml:3305` (`open_out_gen` room-history append) | Room-history append, not broker.log target |
| `relay.ml` SQLite `failwith` (20+ sites) | INTERNAL — DB corruption / programming error, crash appropriate |
| `c2c_mcp.ml` invariant `failwith` (1086, 1091, 1101, 1394) | INTERNAL — programming error, crash appropriate |
| `relay_identity.ml:111` `failwith` | INTERNAL — programming error, crash appropriate |
| `relay_e2e.ml` `failwith` on parse | INTERNAL — corrupt envelope, crash appropriate |

---

## Staleness check

`scripts/audit-staleness-check.sh` output (run against this doc):

```
=== audit-staleness-check: .collab/research/2026-04-29-code-health-audit-3-willow.md ===
base: origin/master

--- Commit SHAs ---
(none found)

--- Issue/PR refs ---
#388 — POSSIBLY ADDRESSED — 388-code-health-audit-second-pass
#338 — POSSIBLY ADDRESSED — c2c_mcp.ml code-health audit
#400 — POSSIBLY ADDRESSED — mkdir_p audit
Result: STALE REFS — some findings may already be resolved.
```

The "stale" result is expected — this audit intentionally cross-references the prior audit documents (which themselves have the SHAs of the slices they describe). The findings in this doc are new to today and reference no in-flight SHAs.

— willow-coder 🌳
