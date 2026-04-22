# Agent Files

c2c unifies agent personas across clients. A single canonical role definition
in `.c2c/roles/<name>.md` is compiled on-the-fly into each client's native
agent file format (OpenCode, Claude Code, Codex, Kimi) whenever you launch an
agent.

> Status: all four clients (OpenCode, Claude Code, Codex, Kimi Code) render
> from the same canonical role file. `c2c roles compile --client all` renders
> to every supported client simultaneously.

## Quick start

Create a new role:

```bash
c2c agent new reviewer --description "Reviews diffs for correctness and style"
```

This writes `.c2c/roles/reviewer.md` with a minimal template. Open it and
flesh out the body (the system prompt for your agent).

Launch OpenCode with that role:

```bash
c2c start opencode --agent reviewer
```

`c2c` reads `.c2c/roles/reviewer.md`, renders it to
`.opencode/agents/reviewer.md` (gitignored), and launches OpenCode with
the agent active.

## Canonical schema

Role files are YAML frontmatter plus a markdown body. The body becomes the
agent's system prompt verbatim.

```yaml
---
description: One-line summary. Shown in menus.
role: subagent           # subagent | primary | all
model: claude-sonnet-4-7 # optional; override per client
c2c:
  alias: reviewer              # optional; defaults to filename
  auto_join_rooms: [swarm-lounge]
opencode:
  theme: tron                  # any bundled or custom theme name
  permission:
    bash: {"*": deny, "just *": allow}
claude:
  tools: [Read, Bash, Edit]
---

You are a careful code reviewer. Favour concrete, line-specific feedback
over generic suggestions.
```

### Field namespaces

Fields are grouped by who consumes them:

| Block                  | Consumer      | Purpose                              |
|------------------------|---------------|--------------------------------------|
| `description`, `role`  | Cross-client  | Common surface across all clients    |
| `model`                | Cross-client  | Default model override (optional)    |
| `c2c`                  | c2c launcher  | Broker alias, auto-join rooms        |
| `opencode`             | OpenCode only | Theme, permission, model options     |
| `claude`               | Claude Code   | Tools list, Claude-specific settings |
| `codex`                | Codex         | (future) Codex-specific settings     |
| `kimi`                 | Kimi          | (future) Kimi-specific settings      |

**Do not put client-specific fields at the top level.** Unknown top-level
keys get forwarded to the model as options (per OpenCode's doc), which can
error. Use the namespaced block for the client you care about.

## Compile model

Compiled agent files are **not** checked into git. Every `c2c start <client>
--agent <name>` call:

1. Reads `.c2c/roles/<name>.md` (canonical)
2. Parses YAML frontmatter + body
3. Renders via the target client's renderer
4. Writes to the client's agent path (gitignored)
5. Launches the client

This means editing a canonical role and restarting is the whole dev loop —
no `compile` step to run by hand.

For debugging, `c2c roles compile <name> --dry-run` prints what would be
written without touching disk or launching.

## Themes

Max maintains ~59 custom OpenCode themes under
`~/.llm-general/themes/opencode/` (tron, tokyo-night, ffx-*, er-ranni-light,
starry-night, etc). Reference any by name in an OpenCode block:

```yaml
opencode:
  theme: tron
```

Inline themes and `{light, dark}` variant pairs are also supported per the
OpenCode fork's theme key. See
`docs/c2c-research/generating-agents/x-oc-fork-writing-agents-w-themes.md`
for shapes.

## CLI reference

### `c2c roles` subcommands

```bash
c2c roles compile                     # compile all roles → default client (opencode)
c2c roles compile --client all        # compile all roles → all supported clients
c2c roles compile my-role --client claude  # compile one role for a specific client
c2c roles compile --dry-run           # print rendered output without writing files
c2c roles validate                    # check canonical role files for completeness
```

### `c2c agent` subcommands

```bash
c2c agent new my-role                # create a new role interactively
c2c agent list                       # list all canonical roles
c2c agent delete my-role             # delete a canonical role
c2c agent rename old-name new-name   # rename a role
```

## Migration from ad-hoc starts

If you used to launch with:

```bash
c2c start opencode -n my-reviewer --kickoff-prompt "you are a reviewer..."
```

Convert to:

```bash
c2c agent new my-reviewer
# edit .c2c/roles/my-reviewer.md, paste kickoff prompt as body
c2c start opencode --agent my-reviewer
```

You get a versioned, diffable persona instead of an ephemeral CLI flag.

## Example canonical roles

See `.c2c/roles/` for the seeded swarm roles (coordinator1, ceo,
galaxy-coder, jungle-coder) as reference implementations.

## See also

- `.collab/agent-files/design-doc-v1.md` — architecture + compile model
- `docs/c2c-research/generating-agents/x-oc-fork-writing-agents-w-themes.md`
  — OpenCode fork theme documentation
