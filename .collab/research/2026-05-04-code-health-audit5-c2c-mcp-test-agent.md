# Code-health Audit-5: `ocaml/c2c_mcp.ml`
**Auditor**: test-agent
**Date**: 2026-05-05
**Scope**: `ocaml/c2c_mcp.ml` (476 lines)
**Context**: Audit-4 previously refactored `send_handlers`. This module was already Slice-0 refactored (#450) — most logic hoisted to `C2c_mcp_helpers`, `C2c_broker`, `C2c_mcp_helpers_post_broker`. This file retains MCP entrypoints and static tool registry.

---

## Summary

File is already lean (476 lines). No functions >100 lines. No duplicate helper definitions found in this file. Two categories of findings: silent exception swallowing and `skills_dir` fallback-to-cwd.

---

## Finding 1: Silent exception swallowing in skills helpers

**Severity**: MEDIUM
**Estimated fix size**: S

Three skills-helper functions use bare `with _` to silently swallow all errors, returning empty results:

```ocaml
(* list_skills, line 336 *)
  with _ -> []

(* parse_skill_frontmatter, lines 368 + 371 *)
  with _ -> ()
  ...
  with _ -> (None, None)

(* get_skill_content, line 382 *)
  with _ -> close_in_noerr ic
  ...
  with _ -> ""
```

**Impact**:
- `list_skills ()` returns `[]` on any error (permissions, disk, malformed directory). Agent sees no skills — silent failure.
- `parse_skill_frontmatter` returns `(None, None)` on any parse error. Skill shows up with no name/description.
- `get_skill_content` returns `""` on any read error. Skill content silently empty.

**Root cause**: These are defensive fallbacks, but the broad `with _` pattern makes debugging impossible — no logging, no distinguishing between "directory missing" and "permission denied."

**Recommendation**: Add targeted exception handlers or a shared `try_or_none` helper. At minimum, log the error to broker audit log so operators can diagnose skill discovery failures.

---

## Finding 2: `skills_dir` falls back to `Sys.getcwd ()` silently

**Severity**: LOW
**Estimated fix size**: XS

```ocaml
(* line 323-327 *)
let skills_dir () =
  let top = match Git_helpers.git_common_dir_parent () with
    | Some t -> t
    | None -> Sys.getcwd ()
  in
  Filename.concat (Filename.concat top ".opencode") "skills"
```

When `git_common_dir_parent` returns `None` (no `.git`, not a git repo), skills directory resolves to `<cwd>/.opencode/skills` rather than failing. This is silently wrong in CI or sandbox environments.

**Impact**: Low — this is a dev-machine skill loading path, not broker state. But it could cause skills to load from the wrong directory if cwd is not the repo root.

**Recommendation**: Either fail explicitly (`failwith "not in a git repo"` or return `None`) or at minimum log the fallback. XS fix.

---

## Finding 3: `failwith` in `tool_definition_name` at module load time

**Severity**: LOW (documented / acceptable)
**Estimated fix size**: M (but low priority)

```ocaml
(* lines 209-210 *)
  | _ -> failwith "tool_definition missing name"
  | _ -> failwith "tool_definition is not an object"
```

These are in `tool_definition_name` called on static data (`base_tool_definitions`). They would fire at module load if a tool definition were malformed. Since `base_tool_definitions` is tested and frozen, this is acceptable — but any future dynamic use of `tool_definition_name` could raise.

**Recommendation**: Consider replacing with `Result.t` or `option` return type for future-proofing. Not urgent.

---

## Findings Summary

| # | Severity | Category | Location | Est. Fix |
|---|----------|----------|----------|----------|
| 1 | MEDIUM | Silent exception swallowing | `list_skills`, `parse_skill_frontmatter`, `get_skill_content` | S |
| 2 | LOW | `skills_dir` silent cwd fallback | line ~323 | XS |
| 3 | LOW | `failwith` on static data | `tool_definition_name` | M (low priority) |

**No issues found in**:
- Functions >100 lines (none exist in this file after #450 Slice 0 refactor)
- Duplicate helper definitions
- Dead code / unreachable branches

**Overall verdict**: File is in good shape. Finding 1 is the only actionable issue — the silent exception swallowing in skills helpers could mask real operational problems. Findings 2 and 3 are low priority.
