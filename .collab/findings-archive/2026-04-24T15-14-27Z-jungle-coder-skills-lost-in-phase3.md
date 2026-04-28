# Bug: Skills CLI Lost During Phase 3 Extraction

## Timestamp
2026-04-25T15:12:00Z

## Symptom
`c2c skills` command missing from binary even though commit `1144b05` ("feat(cli): add c2c skills CLI + 5 canonical swarm skills") added it.

## Root Cause
- Commit `1144b05` added skills CLI (+100 LOC in c2c.ml) + wired `skills_group` into `all_cmds` at line ~4622/~9011
- Commit `8c4f242` ("Phase 3 extract: c2c_rooms.ml") did a **full file replacement** of `c2c.ml` (764 line diff vs 1144b05)
- The Phase 3 extraction was branched from `f28bd54` (docs update) which is a child of `1144b05`
- But when galaxy did the extraction, she appears to have done a full file rewrite rather than a surgical splice
- Skills code (helpers + `skills_group` + `all_cmds` wiring) was **not restored** after the extraction

## Impact
- 5 skills files in `.opencode/skills/` exist but no `c2c skills` command to serve them
- Skills: using-c2c, git-habits, peer-review, sitrep-discipline, ephemeral-agents

## Files Affected
- `ocaml/cli/c2c.ml`: skills_group definition + parse_skill_frontmatter helpers missing
- `.opencode/skills/`: all 5 skills files still present (not touched by extraction)

## Fix Required
1. Restore skills helper functions and `skills_group` definition to `c2c.ml`
2. Wire `skills_group` into `all_cmds`
3. Verify build succeeds and `c2c skills --help` works

## Severity
Medium — skills files exist but are unreachable. Low urgency (workaround: cat the files directly).

## Discovered By
jungle-coder during heartbeat tick investigation of `c2c skills --help`
