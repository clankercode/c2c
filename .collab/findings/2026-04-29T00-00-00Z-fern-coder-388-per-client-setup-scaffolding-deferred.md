# #388 §7 #6: per-client setup scaffolding — MED, deferred

**Reporter**: fern-coder
**Date**: 2026-04-29
**Source**: `.collab/research/2026-04-29-code-health-audit-cairn.md` §7 item #6

## Status: DEFERRED — MED refactor with breakage risk

## Problem

`c2c_setup.ml` has 6 per-client `setup_*` functions that share the same
structural pattern but express it as duplicated control flow:

- `setup_claude` (199 lines)
- `setup_opencode` (166 lines)
- `setup_codex` (78 lines)
- `setup_kimi` (57 lines)
- `setup_gemini` (62 lines)
- `setup_crush` (57 lines)

Each does:
1. Resolve client dir
2. Read existing config (if any) → parse JSON
3. Merge c2c MCP entry
4. Write back with dry-run gate
5. Optionally write hook script

The merge + dry-run write pattern (`json_write_file_or_dryrun`) is
identical across all 6. The surrounding code-walks (dir resolution,
config read, dry-run print) are duplicated verbatim, including the 3
inline `mkdir_p` copies (now fixed as part of #2).

## Proposed Fix

Introduce a `Client_setup` record:
```ocaml
type client_setup = {
  name : string;
  resolve_client_dir : unit -> string;
  config_path : string;
  merge_fn : existing_json -> new_entry_json -> merged_json;
  write_fn : dry_run:bool -> path:string -> json -> unit;
  ?hook_fn : unit -> string;  (* optional hook script writer *)
}
```

A single `run_client_setup : client_setup -> unit` function drives the
common sequence. Each `setup_*` becomes a data record + call to the
driver. This also kills the last `mkdir_p` variation.

## Why deferred

- Six clients with subtly different merge/write semantics — the
  abstraction boundary requires careful design to not break the 5 working
  clients (gemini #406, crush #405 are in-flight)
- Risk of introducing breakage during a busy surge period
- Recommendation: do as a dedicated slice with a per-client test
  harness once the current in-flight installs are settled

## Out-of-scope for this session

— fern-coder
