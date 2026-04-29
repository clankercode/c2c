# Finding: #388 audit — `c2c_io.ml` shipped but call sites still use local duplicates

**Agent**: willow-coder
**Date**: 2026-04-29
**Severity**: LOW
**Status**: CLOSED (call-site migration committed, SHA=ecd262d7)
**388 item**: second-pass finding #1 (call-site migration phase)

## Problem

Six distinct I/O helper patterns are each implemented multiple times across `ocaml/`:

| Pattern | Distinct defs | Representative sites |
|---|---|---|
| `mkdir_p` / `mkdir_p_mode` | 16 | `c2c_setup.ml:214` (dry-run variant), `c2c_relay_managed.ml:32`, `c2c_migrate.ml:121` |
| `read_file` / `read_file_trimmed` | 6 | `c2c.ml:3480,7539`, `c2c_memory.ml:70-79`, `c2c_stats.ml:291-296`, `c2c_mcp.ml:5513` |
| `write_file` | 6 | `c2c_memory.ml`, `c2c_stats.ml`, `c2c_mcp.ml:5513` |
| `with_temp_dir` | 5 | test fixtures (scattered) |
| `atomic_write_json` | partial | `c2c_utils.ml:35` — exists but is not used by most call sites |

Note: `C2c_utils` already has `let mkdir_p = C2c_mcp.mkdir_p` and `atomic_write_json` but the main call sites don't use them.

## Fix shape

Create `ocaml/c2c_io.ml` (or extend `C2c_utils`) with:
```ocaml
val mkdir_p : ?mode:int -> string -> unit
val mkdir_p_dry_run : string -> [`Would_create | `Exists | `Error of string]
  (** c2c_setup.ml's dry-run variant — only one site needs this *)
val read_file : string -> string
val read_file_trimmed : string -> string  (** trim-newlines variant *)
val write_file : string -> string -> unit
val atomic_write_file : string -> string -> unit
val with_temp_dir : (string -> 'a Lwt.t) -> 'a Lwt.t
```

Production + test-fixture variants share the same impl (test fixtures use the same `C2C_SEND_MESSAGE_FIXTURE=1` gate already present).

## Risk

LOW. Pure mechanical refactor; all variants share the same POSIX semantics. Must preserve the `0o600` permission mode on broker-private files (`open_out_gen [Open_creat; Open_wronly; Open_trunc] 0o600`) — the `mkdir_p_mode` callers that use `0o755` vs `0o700` have different security contexts that must be preserved.

## Estimate

3-4h including build + review-and-fix.

## Convergence status (update 2026-04-29T10:30Z)

**`c2c_io.ml` is already on origin/master** (`4f068a2d`). The canonical module ships:
- `mkdir_p` (recursive, idempotent, default 0o755)
- `read_file` (slurp, raises Sys_error on I/O failure)
- `read_file_opt` (best-effort variant, returns "" on error)
- `write_file` (truncating write)

**Committed migration** (SHA=ecd262d7): replaced the single local `read_file` def in `c2c_mcp.ml` memory_list handler with `C2c_io.read_file_opt`. Net -5 LOC.

**Remaining local defs**: all others are `C2c_io.read_file` / `C2c_io.read_file_opt` / `C2c_utils.read_file` aliases (c2c_stats, c2c_memory, c2c_utils, c2c.ml). No further duplication on `read_file`.

**c2c_agent.ml `read_all`**: uses `Bytes.create` + `really_input` (slightly different from `C2c_io.read_file`'s `really_input_string`). Not a clean migration without semantic change — left as-is.

**mkdir_p**: `c2c_mcp.ml` re-exports via `C2c_io.mkdir_p`; `c2c_start.ml` delegates directly. No duplication.

**write_file**: all modules use `C2c_io.write_file` or its alias. No duplication.
