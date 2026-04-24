# #164: Skills MCP Prompts Surface

## Goal
Expose `.opencode/skills/<name>/SKILL.md` files as MCP prompts via `prompts/list` and `prompts/get`, so Claude Code sessions can discover and invoke c2c swarm skills natively through the MCP protocol.

## Background
- Skills are already extracted as a CLI module (`c2c skills list/serve`) — Phase 3, commit f1e1a4b
- The MCP server (`c2c_mcp.ml`) currently handles: `initialize`, `tools/list`, `tools/call`, `ping`
- `prompts/list` and `prompts/get` are standard MCP protocol methods
- Skills dir: `.opencode/skills/<name>/SKILL.md`

## Design

### MCP Protocol Surface

**`prompts/list`** — returns all available skills as prompts:
```json
{
  "prompts": [
    { "name": "heartbeat", "description": "how to use the 'monitor' plugin/tool to create a heartbeat." },
    { "name": "review-and-fix", "description": "Use when a task needs a disciplined review/fix loop..." },
    ...
  ]
}
```

**`prompts/get`** — params: `{ "name": "heartbeat" }` — returns per MCP spec 2025-06-18:
```json
{
  "description": "<skill description>",
  "messages": [
    { "role": "user", "content": { "type": "text", "text": "<full SKILL.md content>" } }
  ]
}
```
Note: `content` is a structured object `{type: "text", text: "..."}`, NOT a raw string.

### Implementation

1. **`c2c_mcp.ml`** — add two cases to `handle_request`:
   ```ocaml
   | Some id, "prompts/list" ->
       let prompts = list_skills_as_prompts () in
       Lwt.return_some (jsonrpc_response ~id (`Assoc [("prompts", `List prompts)]))
   | Some id, "prompts/get" ->
       let name = try params |> member "name" |> to_string with _ -> "" in
       match get_skill name with
       | Some (description, content) ->
           let prompt_msg = `Assoc [("role", `String "user"); ("content", `Assoc [("type", `String "text"); ("text", `String content)])] in
           Lwt.return_some (jsonrpc_response ~id (`Assoc [("description", `String description); ("messages", `List [prompt_msg])]))
       | None ->
           Lwt.return_some (jsonrpc_error ~id ~code:(-32602) ~message:("Unknown skill: " ^ name))
   ```

2. **`capabilities`** — add `prompts` to server capabilities:
   ```ocaml
   let capabilities = `Assoc
     [ ("prompts", `Assoc [])
     ; ("tools", `Assoc [("listChanged", `Bool true)])
     ; ...
     ]
   ```

3. **Helper functions** — in `c2c_mcp.ml` (or a new `c2c_skills_mcp.ml`):
   - `list_skills_as_prompts ()` — reads `.opencode/skills/`, parses each `SKILL.md` frontmatter, returns `prompt` JSON list
   - `get_skill_content name` — reads `.opencode/skills/<name>/SKILL.md`, returns full content as string

4. **Error handling**: `prompts/get` with unknown skill name → JSON-RPC error `-32602` (invalid params)

### File Changes
- `ocaml/c2c_mcp.ml`: ~30 LOC additions (two match arms + capability update + two helpers)

### Tier
- `c2c_mcp.ml` modifications → Tier 1 (requires coordinator1 sign-off before push)

## Status
- [x] Draft this doc → DRAFT
- [x] Get coordinator1 sign-off on design (coord-PASS @ 22:51)
- [ ] Implement in worktree
- [ ] Test: unit tests for prompts/list + prompts/get
- [ ] Peer review (test-agent or jungle)
- [ ] Coordinator1 sign-off for push
