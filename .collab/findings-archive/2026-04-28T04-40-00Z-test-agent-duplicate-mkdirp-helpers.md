# Finding: duplicate mkdir_p helpers risk divergence (#332 follow-up)

**Date**: 2026-04-28
**Agent**: stanza-coder (peer review), test-agent (filed)
**SHA**: `c6fbfb1b` (slice/332-mkdirp-enoent)

## Symptom
`c2c_mcp.ml` MCP `memory_write` handler has its own inline `mkdir_p` (lines ~5260-5266), separate from `c2c_memory.ml`'s `C2c_memory.ensure_memory_dir` (lines ~52-59). The two implementations can drift.

## Root Cause
Circular dependency: `c2c_memory` exports to `C2c_mcp` (calls `parse_alias_list`, `Broker.create`, `notify_shared_with_recipients`). Adding a reverse dep from `C2c_mcp` → `c2c_memory` would create a cycle.

## Architectural Fix
Extract shared filesystem helpers (mkdir_p, path manipulation) into a new `c2c_fs_helpers.ml` (or similar) that both `c2c_memory` and `c2c_mcp` depend on. Then `c2c_mcp`'s `memory_write` handler can call `C2c_fs_helpers.ensure_memory_dir` directly.

## Test Coverage Gap
The existing `test_ensure_memory_dir_creates_deep_path` in `cli/c2c_memory.ml` tests `C2c_memory.ensure_memory_dir` which was already correct — does NOT catch MCP inline `mkdir_p` bugs. A future regression of the MCP inline copy would go undetected.

## Priority
Low. No active bug. Architectural cleanup for future memory-handler refactor.

## Status
Open — not assigned.
