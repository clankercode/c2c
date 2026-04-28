# Peer Review Findings: galaxy #164 MCP prompts @ b24894a

## Date: 2026-04-25
## Reviewer: test-agent
## Verdict: PASS (against b24894a — coordinator's fix commit)

## Build Status
All 3 binaries built successfully:
- c2c.exe ✓
- c2c_mcp_server.exe ✓
- c2c_inbox_hook.exe ✓

## Files Reviewed
- ocaml/c2c_mcp.ml (skills_dir, list_skills, parse_skill_frontmatter, get_skill_content, list_skills_as_prompts, get_skill, prompts/list and prompts/get handlers)

## skills_dir Fix (b24894a — coordinator's own fix)

**OLD (ba73d1e)**: `Sys.getcwd ()` — unreliable since MCP server CWD varies by client launcher.

**FIXED (b24894a)**: Uses `Git_helpers.git_repo_toplevel ()` with `Sys.getcwd ()` fallback when not in a git repo.

Correct. This is the right approach.

## prompts/list Handler — PASS

Returns skills as MCP prompts array. Each skill has `name` and optional `description` (from frontmatter). Handles missing frontmatter gracefully by omitting description.

## prompts/get Handler — PASS

Returns full SKILL.md content as MCP prompt message:
```json
{"role": "user", "content": {"type": "text", "text": "<full SKILL.md>"}}
```
Returns `-32602` error for unknown skills.

## Non-blocking Notes
- `parse_skill_frontmatter`: `lines := line :: !lines` accumulates reversed lines but is never read — dead code, harmless
- `get_skill_content`: potential fd leak on exception between `open_in` and `while` loop — low severity
- Quoted descriptions correctly unquoted via `strip_quotes` ✓
- 20-line frontmatter scan limit has a comment explaining why ✓
