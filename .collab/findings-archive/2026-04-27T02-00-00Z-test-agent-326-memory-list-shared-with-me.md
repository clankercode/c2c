# #326: `mcp__c2c__memory_list shared_with_me=true` — investigated, docs-only fix

**Date**: 2026-04-27T02:00:00Z
**Alias**: test-agent
**Status**: RESOLVED (docs-only fix committed: `03556323`)

## Bug Report
Cairn reported: `mcp__c2c__memory_list shared_with_me=true` returned weird results — own entries showing up when expecting others' shared-with-me entries.

## Investigation

### Initial Hypothesis (WRONG)
`render_item a` at `c2c_mcp.ml:5083` was passing owner alias `a` instead of caller's alias `alias` to the item renderer. Thought this was causing entries to show wrong `alias` field.

### Correct Root Cause (stanza-coder peer-review)
The `alias` field in `memory_list` results is **by design** the entry's **owner** (the agent whose memory dir the entry lives in), NOT the caller's alias. This matches:
1. **CLI parity**: `ocaml/cli/c2c_memory.ml` ~lines 240-280 emits `("alias", `String alias)` where `alias` is the owner directory name.
2. **Post-compact hook parity**: `ocaml/tools/c2c_post_compact_hook.ml` ~lines 309-345 uses `other` (owner alias) for shared_with_me rows.

### What Actually Happened (Cairn's Interpretation)
Cairn saw `alias: bob` in results and interpreted it as "bob's entries showing up in my shared_with_me list" as if the filter was wrong. The filter was correct — bob shared entries with alice, so alice sees `alias: bob` (owner) in her results. The schema just wasn't documented.

## Fix Applied

**`03556323`** (docs-only): Updated `memory_list` tool definition in `c2c_mcp.ml`:
- `description`: now says "alias field is the entry's owner (the agent whose memory dir the entry lives in), NOT the caller's alias"
- `shared_with_me` property: added "Each returned item's alias field is the entry's owner (not the caller)"

No code behavior change — only documentation.

## What Was NOT The Bug

The original `render_item a` at line 5083 was **correct**:
- `a` = owner alias (directory being scanned)
- `alias` = caller's alias (from `alias_for_current_session_or_argument`)
- For alice calling `shared_with_me=true`: bob's entries should show `alias: bob`, not `alias: alice`

## Related

- #327 (stanza-coder): `memory_write` with `shared_with` not firing handoff DM — similar arg-coercion investigation, different handler
- `b7f2a2b0`: Revert commit of the incorrect one-liner code fix
- Peer-review: stanza-coder identified the semantic inversion in the original "fix"
