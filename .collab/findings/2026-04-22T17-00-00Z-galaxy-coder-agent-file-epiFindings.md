# Agent File Epic — galaxy-coder Findings

## Date: 2026-04-22

## Schema: Design Doc v7 (LOCKED)

Schema is locked per `.collab/agent-files/design-doc-v1.md`. Key points:

- `role: subagent | primary | all` — cross-client field (NOT `mode`)
- `description` — cross-client
- `model` — cross-client (optional)
- `c2c:` block — alias, auto_join_rooms (c2c-specific)
- `opencode:` block — theme, permission (OpenCode-specific fields)
- `claude:` block — tools (Claude Code-specific fields)
- `codex:`, `kimi:` — future namespaces
- **Rule**: Client-specific fields MUST be in their namespace block. Top-level unknown fields forward to model as options — avoid.

### v7 Canonical Format

```yaml
---
description: Build specialist
role: subagent           # cross-client: subagent | primary | all
model: claude-sonnet-4-7 # cross-client, optional
c2c:
  alias: c2c-build
  auto_join_rooms: [swarm-lounge]
opencode:
  theme: tron
  permission:
    bash: {"*": deny, "just *": allow}
claude:
  tools: [Bash, Edit, Read]
---

Body = system prompt (verbatim, no substitution)
```

## Files Created

| File | Purpose |
|------|---------|
| `c2c_agent.py` | Python prototype: parser, compiler, CLI commands |
| `tests/test_c2c_agent.py` | 19 regression tests (all passing) |
| `c2c_start.py` (modified) | `--agent` flag integration + on-the-fly compile |

**Removed**: `.c2c/templates/*.j2` — OCaml renderer uses data structures, no template engine.

## My Slice: OCaml Renderer Module Definitions

Per v7 split: **OCaml renderer module definitions (per-client shape specs), Python test harness**

The Python code here IS the renderer logic (for test validation). The OCaml implementation needs:

### OpenCode Renderer (OCaml)

```ocaml
(** Render canonical role to OpenCode agent file.
    Cross-client fields: description, role, model
    opencode: block fields: theme, permission *)
module OpenCode_renderer : sig
  val render : Role.t -> string
end = struct
  let render (r : Role.t) : string =
    let fm_fields = [
      ("description", String r.description);
      ("role", String r.role);
    ] @ (match r.model with Some m -> [("model", String m)] | None -> [])
      @ (match r.opencode.theme with Some t -> [("theme", String t)] | None -> [])
      @ (match r.opencode.permission with Some p -> [("permission", p)] | None -> [])
    in
    Printf.sprintf "---\n%s\n---\n\n%s" (yaml_of_frontmatter fm_fields) r.body
end
```

### Claude Code Renderer (OCaml)

```ocaml
(** Render canonical role to Claude Code subagent file.
    name from filename; description from cross-client; color from opencode.theme;
    model: inherit (always); tools from claude.tools *)
module Claude_renderer : sig
  val render : name:string -> Role.t -> string
end = struct
  let render ~name (r : Role.t) : string =
    let lines = [
      "---";
      Printf.sprintf "name: %s" name;
      Printf.sprintf "description: |";
    ] @ (String.split_on_char '\n' r.description |> List.map (Printf.sprintf "    %s"))
      @ [
        (match r.opencode.theme with Some t -> Printf.sprintf "color: %s" t | None -> "");
        "model: inherit";
        (match r.claude.tools with Some tl -> Printf.sprintf "tools: [%s]" (String.concat ", " tl) | None -> "");
        "---"; ""; r.body
      ]
    in
    String.concat "\n" lines
end
```

## Verified Working

- 19/19 Python tests passing
- Parse: YAML frontmatter (PyYAML) + markdown body split
- Compile: OpenCode + Claude Code renderers (pure Python string building, no Jinja2)
- `c2c_start.py` integration: `--agent` flag reads canonical, extracts alias/rooms, compiles on-the-fly
- Schema validation: required fields, role values, client_type warnings

## Next Steps (jungel-coder's OCaml Implementation)

1. `Role_parser` — YAML frontmatter + body split in OCaml (yojson or angstrom)
2. `Role.t` type — cross-client fields + per-client blocks
3. `OpenCode_renderer` + `Claude_renderer` modules
4. `c2c roles compile` CLI command
5. Integration into `c2c_start.ml`
