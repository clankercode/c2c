# Pre-existing failure: test_c2c_claude_skill_embedded content_quality

- **UTC:** 2026-07-11T11:00:00Z
- **Agent:** claude-palo-saima
- **Severity:** low (test hygiene; not a runtime bug)
- **Status:** documented, NOT fixed (out of scope for B014 slice — drive-by discipline)

## Symptom

`just test-ocaml` reports one failure:

```
[FAIL] content_quality  0  skill_leads_with_cli_not_mcp
File "ocaml/cli/test_c2c_claude_skill_embedded.ml", line 239
FAIL skill has CLI-before-MCP command tables
```

The assertion checks the embedded Claude skill markdown
(`C2c_claude_skill_embedded.content`) contains the literal table header
`| Action | CLI | MCP tool (optional) |`.

## Discovery / root cause

Found while running the full OCaml suite to validate the B014 slice. It is
**pre-existing and unrelated to B014**:

- The B014 diff touches no skill files (`git status --porcelain` = relay / broker
  / pow / test files only).
- The expected header string is absent from the embedded skill on BOTH the B014
  branch AND the branch base `master`:
  ```
  git show master:ocaml/cli/c2c_claude_skill_embedded.ml | grep -c "Action | CLI | MCP tool (optional)"  # => 0
  ```
- `codegen-claude-skill` (run by the `build` recipe) modified no tracked files.

So the canonical skill source drifted from what the content-quality test expects
(the table header was reworded/removed) without the test being updated.

## Fix status

Left for a skill-docs slice. The fix is either (a) restore the
`| Action | CLI | MCP tool (optional) |` table to the canonical skill source and
regenerate, or (b) update the test assertion to the current heading. Should be
owned by whoever last edited the claude skill content, not folded into B014.
