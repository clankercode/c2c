# Finding: c2c_mcp.ml / c2c_memory.ml mkdir_p duplication (#396)

**Date**: 2026-04-28
**Agent**: test-agent
**Source**: #332 investigation; peer review by stanza-coder

## Problem
`c2c_mcp.ml` MCP `memory_write` handler (~line 5260) has its own inline `mkdir_p` implementation, separate from `C2c_memory.ensure_memory_dir` (~cli/c2c_memory.ml:52). These can diverge on future edits.

## Depency Arrows
- `c2c_memory.ml` → `C2c_mcp` (exports `parse_alias_list`, `Broker.create`, `notify_shared_with_recipients`)
- Adding `C2c_mcp` → `c2c_memory` would create a cycle

## Fix (recommended)
Extract shared filesystem helpers into a new `c2c_fs_helpers.ml` module:
```ocaml
(* c2c_fs_helpers.ml *)
let ensure_memory_dir target =
  let rec mkdir_p d = ... in
  mkdir_p target
```
Both `c2c_memory.ml` and `c2c_mcp.ml` then depend on `c2c_fs_helpers`.

## Status
Low priority. Not a regression risk right now. No active bug filed.
