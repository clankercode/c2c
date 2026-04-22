# Agent Files Epic — Design Doc v7 (FINAL — schema locked)

## Context

c2c is the hub for multi-client persona parity. Canonical role definitions live in
`.c2c/roles/<name>.md` and are compiled on-the-fly into each client's native agent file format.

**Git policy**: Compiled artifacts are NOT checked in. Canonical `.c2c/roles/` is the only committed source.

**Implementation**: Pure OCaml (no Python). Python only for test scaffolding.

## Canonical Schema

```yaml
---
description: Build specialist
role: subagent           # cross-client: subagent | primary | all
model: claude-sonnet-4-7   # cross-client, optional
c2c:
  alias: c2c-build
  auto_join_rooms: [swarm-lounge]
opencode:
  theme: tron
  permission:
    bash: {"*": deny, "just *": allow}
claude:
  tools: [Bash, Edit, Read]
codex:
  # future
kimi:
  # future
---

Body = system prompt (verbatim, no substitution)
```

### Field Namespaces

| Namespace | Owner | Purpose |
|-----------|-------|---------|
| `description`, `role`, `model` | Cross-client | Used by all clients |
| `c2c` | c2c | Registration alias, auto-join rooms |
| `opencode` | OpenCode | OpenCode-specific fields |
| `claude` | Claude Code | Claude Code-specific fields |
| `codex` | Codex | Future |
| `kimi` | Kimi | Future |

**Rule**: Client-specific fields MUST be in the namespaced block. Top-level unknown fields get forwarded to the model as options (per OpenCode docs) — we avoid this.

## Architecture (OCaml)

```
Canonical role file (.c2c/roles/<name>.md)
        ↓
  Role_parser (YAML frontmatter + markdown body split)
        ↓
  Role.t = { description, role, model, c2c, opencode, claude, codex, kimi, body }
        ↓
  Client_renderer (OpenCode | Claude | Codex | Kimi)
        ↓
  Compiled agent file (written to .opencode/agents/<name>.md, etc.)
```

Each client renderer is a pure function `canonical_role -> string`:

```ocaml
module OpenCode_renderer : sig
  val render : Role.t -> string
end = struct
  let render (r : Role.t) : string =
    let fm = List.concat [cross_client_fields r; r.opencode] in
    Printf.sprintf "---\n%s\n---\n\n%s" (yaml_of_frontmatter fm) r.body
end
```

No template engine. Body is verbatim. Frontmatter is built as a data structure and serialized.

## CLI Surface (OCaml, ocaml/cli/c2c.ml)

### `c2c agent new <name> [--description DESC]`
Creates `.c2c/roles/<name>.md` from template.

### `c2c start <client> --agent <name>`
On-the-fly compile + launch:
1. Read canonical `.c2c/roles/<name>.md`
2. Parse YAML frontmatter + body into `Role.t`
3. Render using target client's renderer
4. Write to client's agent path (gitignored)
5. Launch client

### `c2c roles compile [<name>] [--dry-run]`
Debug command: compile and print output without writing or launching.

## Directory Structure

- `.c2c/roles/<name>.md` — canonical source (flat list, git-tracked)
- `.opencode/agents/<name>.md` — compiled output (gitignored)
- `.claude/agents/<name>.md` — compiled output (gitignored)

## Migration: existing role files

Existing `.c2c/roles/{ceo,galaxy-coder,jungle-coder,coordinator1,tauri-expert,...}.md` (currently 1-line descriptions) get expanded into full canonical format with proper persona body + c2c metadata.

## Implementation Split

| Who | Slice |
|-----|-------|
| ceo (me) | Schema design, design doc |
| jungel-coder | OCaml implementation: parser, compiler, CLI commands |
| galaxy-coder | OCaml renderer module definitions (per-client shape specs), Python test harness |
| coordinator1 | docs + migration of 9 existing role files |

## CLI UX (v1 polish bar)

Substantial commands (`c2c agent new`, `c2c start --agent`, `c2c roles compile`) print:
1. **ASCII-art banner** header — themed per command
2. Well-formatted, **mostly append-only** body (progressive reveal)
3. Occasional bottom-line rewrite for in-progress status (single refreshing line)

No TUI library. Plain stdin + ANSI. Quality bar: `cargo init`, `gh repo create`, `npm init`.

## Theme subset for v1 testing

Don't copy all 58 themes in from `~/.llm-general/themes/opencode/`. Start curated:

- `exp33-gilded`, `exp33-black`, `exp33-chroma`
- `ffx-yuna`, `ffx-rikku`, `ffx-bevelle`, `ffx-zanarkand`
- `lotr-forge`
- `er-ranni`, `er-nightreign`, `er-melina`

11 themes — enough variety without bulk. Full set unlock post-MVP.

Caveat: themes were converted from openclaude → opencode; highlight colors may be lost. Adapting theme JSON is fair game when rendered output looks wrong.

## Status

Schema locked. CLI UX pattern locked. Theme subset locked. Implementation queued for jungel-coder (OCaml) + galaxy-coder (optional Banner module).