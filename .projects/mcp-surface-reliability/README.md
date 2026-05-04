# MCP Surface Reliability

**Status**: active

## Goal
MCP tool surface should be testable, observable, and free of silent-mismatch hazards. Two MCP-only regressions in one hour on 2026-04-27 (#326/#327) showed CLI-only verification is insufficient.

## Key items
- #326 (memory_list shared_with_me=true semantics) — closed `e9c39714→a70b32df`
- #327 (send-memory handoff DM did not fire on memory_write with shared_with) — closed `b7b4997a`
- #331 — MCP regression test suite landed `a49480d0`
- #332 (mkdir_p ENOENT for missing parent dirs) — closed `68d087d4`
- #346 (`C2C_MCP_AUTO_DRAIN_CHANNEL` default-flip) — closed `b5316cd0`

## Next
Track for next regression class. Monitor in dogfood.

## References
- `todo-ongoing.txt` entry: MCP surface reliability
- Cluster: #326/#327/#331/#332/#346
