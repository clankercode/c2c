# #146-prime: kimi-yaml renderer design

## Background

#146 established that opencode/claude use markdown agent files (YAML frontmatter + body)
but kimi uses YAML AgentSpec (`~/.kimi/agents/<name>/agent.yaml`) with a separate
`system_prompt_path` pointing to a `.md` file. The current `Kimi_renderer` outputs
markdown-with-frontmatter which is INERT — kimi-cli does not read `.md` files from
`~/.kimi/agents/`.

## Goal

Render c2c canonical roles to native kimi-cli AgentSpec YAML so that
`c2c start kimi --agent <name>` produces a functional custom agent.

## kimi-cli AgentSpec schema (v1)

From `kimi_cli/agentspec.py`:

```yaml
version: 1
agent:
  name: string                    # required
  system_prompt_path: Path        # required — resolved relative to agent.yaml
  system_prompt_args: dict        # optional — template args for system prompt
  model: string | None            # optional — model alias
  when_to_use: string | None      # optional — usage guidance
  tools: list[str] | None         # required (or inherit)
  allowed_tools: list[str] | None # optional
  exclude_tools: list[str]        # optional
  subagents: dict[str, SubagentSpec] | None  # optional
```

`SubagentSpec`: `{path: Path, description: string}`

Inheritance via `extend: default` or `extend: <file>` — unlisted fields are inherited.

## Design decisions

### 1. File layout

```
~/.kimi/agents/<name>/
  agent.yaml      # AgentSpec
  system.md       # system prompt (body from c2c role)
```

`system_prompt_path: ./system.md` — relative to `agent.yaml` parent.

### 2. Field mapping (c2c role → AgentSpec)

| c2c role field | AgentSpec field | Notes |
|----------------|-----------------|-------|
| `name` (param) | `agent.name` | Instance/role name |
| `body` | `system.md` content | Full system prompt text |
| `model` / `resolved_pmodel` | `agent.model` | Only if single-client role |
| `description` | `agent.when_to_use` | v1: optional, may skip |
| (none) | `agent.extend` | `default` to inherit tool set |
| `kimi.tools` | `agent.tools` | Override from role custom fields |
| `kimi.allowed_tools` | `agent.allowed_tools` | Override |
| `kimi.exclude_tools` | `agent.exclude_tools` | Override |
| `kimi.subagents` | `agent.subagents` | v1: skip (empty) |

### 3. Tool strategy

Use `extend: default` to inherit the full default tool set from kimi-cli.
This avoids hard-coding tool names that may change across kimi-cli versions.
If a role specifies `kimi.exclude_tools`, we emit `exclude_tools`.

### 4. Changes to OCaml code

**`c2c_role.mli`**:
- `Kimi_renderer.render` gains `~name` parameter (matching `Claude_renderer`)

**`c2c_role.ml`**:
- `Kimi_renderer.render` outputs YAML AgentSpec instead of markdown-with-frontmatter
- `render_for_client` passes `~name` to `Kimi_renderer.render`
- `agent_file_path` for kimi returns `.kimi/agents/<name>/agent.yaml`

**`c2c_commands.ml`**:
- `write_agent_file` for kimi writes `agent.yaml` (not `.md`)
- Add `write_kimi_system_prompt` to write `system.md` alongside

**`c2c.ml` (cmd_start)**:
- When `client = "kimi"`, write both `agent.yaml` AND `system.md`
- Pass `--agent-file <path>` in launch args when `agent_name` is set

**`c2c_agent.ml` (roles compile/validate)**:
- When `client = "kimi"`, write both files

**`c2c_start.ml`**:
- `KimiAdapter.build_start_args`: when `agent_name` is set, append `--agent-file <path>`

**`test_c2c_role.ml`**:
- Update `test_kimi_renderer` expectations to match YAML output
- Add test for `system_prompt_path` presence

### 5. Backward compatibility

- Existing `.kimi/agents/<name>.md` files become orphaned (harmless)
- `c2c start kimi` without `--agent` is unchanged
- `c2c start kimi --agent <name>` now actually works

## Open questions

1. Should `description` map to `when_to_use`? Probably yes for v1.
2. Should we support `system_prompt_args` for template substitution? Out of scope for v1.
3. Subagents: c2c roles have no subagent concept yet. Skip for v1.

## Implementation sketch

```ocaml
module Kimi_renderer = struct
  let render ?resolved_pmodel ~name (r : t) =
    let lines = ref [] in
    lines := "version: 1" :: !lines;
    lines := "agent:" :: !lines;
    lines := ("  name: " ^ yaml_scalar name) :: !lines;
    lines := "  system_prompt_path: ./system.md" :: !lines;
    let single_client = List.length r.compatible_clients = 1 in
    let model_to_emit = if single_client then (match resolved_pmodel with Some m -> Some m | None -> r.model) else None in
    (match model_to_emit with Some m -> lines := ("  model: " ^ m) :: !lines | None -> ());
    (match r.description with "" -> () | d -> lines := ("  when_to_use: " ^ yaml_scalar d) :: !lines);
    lines := "  extend: default" :: !lines;
    (* tools / allowed_tools / exclude_tools from r.kimi custom fields *)
    ...
    String.concat "\n" (List.rev !lines)
end
```

## Acceptance criteria

- [ ] `c2c roles compile` writes `.kimi/agents/<name>/agent.yaml` + `system.md`
- [ ] `c2c start kimi --agent <name>` passes `--agent-file` and launches with custom agent
- [ ] `Kimi_renderer.render` tests pass with YAML output
- [ ] Build clean (`just check` rc=0)
