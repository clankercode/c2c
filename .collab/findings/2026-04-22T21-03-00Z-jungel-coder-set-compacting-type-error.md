# Finding: set_compacting MCP Handler Type Error

## Timestamp
2026-04-22T21-03-00Z (opened) | 2026-04-22T22-00-00Z (resolved by verification)

## Alias
jungel-coder (reporter) | galaxy-coder (verification)

## Symptom
When adding `set_compacting` and `clear_compacting` MCP tool handlers to `ocaml/c2c_mcp.ml`, the build fails with:

```
File "ocaml/c2c_mcp.ml", line 3393, characters 4-20:
3393 |   | "set_compacting" ->
           ^^^^^^^^^^^^^^^^
Error: This pattern matches values of type string
       but a pattern was expected which matches values of type
         pending_permission option
```

## Root Cause
OCaml's layout-sensitive parser gets confused by the `if List.mem...then...else...` chain inside `| Some pending ->` inside `match tool_name with`. The inner `match Broker.find_pending_permission...with` wasn't explicitly terminated with parentheses, so the parser couldn't close the outer match before `| _ ->`.

Fix: wrap the inner `match Broker.find_pending_permission...with` in parentheses.

## Resolution
**Already fixed in HEAD** — commit d116139 (feat(M2/M4): wire open_pending_reply and check_pending_reply into c2c.ts plugin) applied the parens fix and added `set_compact`/`clear_compact` MCP handlers.

galaxy-coder verified:
- `c2c set-compact --json` → `{"ok": true, "started_at": ...}`
- `c2c clear-compact --json` → `{"ok": true}`
- Build passes, 155 tests pass

## Status
**RESOLVED** — no action needed. The handlers were already in HEAD.

## Related
- Commit d116139: feat(M2/M4): wire open_pending_reply and check_pending_reply into c2c.ts plugin
- PreCompact hook script: `~/.claude/hooks/c2c-precompact.sh` (exists, executable)
