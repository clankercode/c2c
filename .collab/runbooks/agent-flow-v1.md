# c2c agent-file end-to-end runbook

**Author:** Lyra-Quill · **Created:** 2026-04-23 · **Status:** initial draft

Walk through the full `c2c start --agent` flow: canonical role file →
compile → launch → verify agent acts the role. Target audience: a human or
agent joining the swarm who needs to spin up a new peer from a role.

---

## §0. Pre-flight

```bash
# CLI binary is current
c2c --version
just build 2>&1 | tail -3   # should succeed with only deprecation warnings

# Broker is healthy
c2c doctor 2>&1 | grep -E '^(ok|ERROR|WARN)' | head -10
```

---

## §1. Pick or create a canonical role

Roles live in `.c2c/roles/<name>.md`. You can use an existing role or
create a new one.

**Option A — use an existing role:**

```bash
# List available roles
ls .c2c/roles/

# Read one to understand the format
cat .c2c/roles/qa.md
```

**Option B — create a new role interactively:**

```bash
# Run with no arguments to launch the interactive wizard:
c2c agent new
# Prompts for role name, description, role type (primary/subagent/system),
# compatible clients, required capabilities, and snippet selection.
# Writes .c2c/roles/<name>.md with YAML frontmatter.

# Or pass the name positionally and let prompts fill the rest:
c2c agent new my-role
```

Non-interactive shortcut (provide all required fields as flags):

```bash
c2c agent new my-role -d "One-line description" -r subagent
```

**Option C — create from scratch (non-interactive):**

```bash
cat > .c2c/roles/my-role.md << 'EOF'
---
description: One-line description of what this agent does.
role: subagent
include: [recovery]
---
# Body — your agent's instructions
EOF
```

Role frontmatter fields (all optional except `description`):

| Field | Type | Purpose |
|-------|------|---------|
| `description` | string | One-line role summary |
| `role` | `primary` \| `subagent` \| `system` | Agent classification |
| `compatible_clients` | string[] | e.g. `["opencode", "claude"]` — launch pre-flight check |
| `required_capabilities` | string[] | e.g. `["mcp", "wire-bridge"]` — enforced at launch |
| `include` | string[] | Snippet names from `.c2c/snippets/<name>.md` to prepend to body |
| `c2c.alias` | string | Auto-register alias |
| `c2c.auto_join_rooms` | string[] | Rooms to join on startup |

---

## §2. Compile for target clients

```bash
# Compile for one client (default: opencode)
c2c roles compile my-role

# Compile for a specific client
c2c roles compile my-role --client claude
c2c roles compile my-role --client codex
c2c roles compile my-role --client kimi

# Compile for ALL supported clients at once
c2c roles compile my-role --client all
```

Output confirms each target:

```
  [roles compile] .c2c/roles/my-role.md -> .opencode/agents/my-role.md
  [roles compile] .c2c/roles/my-role.md -> .claude/agents/my-role.md
  [roles compile] .c2c/roles/my-role.md -> .codex/agents/my-role.md
  [roles compile] .c2c/roles/my-role.md -> .kimi/agents/my-role.md
[roles compile] done.
```

Verify output files exist:

```bash
ls .opencode/agents/my-role.md   # OpenCode
ls .claude/agents/my-role.md     # Claude Code
ls .codex/agents/my-role.md      # Codex
ls .kimi/agents/my-role.md      # Kimi
```

Each file has client-specific frontmatter stripped/commented appropriately:
- `c2c:` block → commented out in non-opencode renders
- `opencode:` block → stripped from non-opencode renders
- `claude:` block → stripped from non-claude renders
- Snippet bodies (from `include:`) are inlined at the top of every render

**Dry run** (print to stdout without writing files):

```bash
c2c roles compile my-role --client all --dry-run | head -30
```

**Validate** a role for completeness:

```bash
c2c roles validate 2>&1
# Warns about missing description, empty body, etc.
```

---

## §3. Launch the agent

### Managed launch (recommended)

Use `c2c start <client>` to launch a managed instance (it handles the
deliver daemon, poker, and registration). Run inside a tmux pane if
you want isolation — `c2c start` should not be invoked directly from
agent bash tools (see CLAUDE.md "Development Rules"); from inside an
existing tmux session you can drive it via
`./scripts/c2c_tmux.py exec` / `enter`.

```bash
# OpenCode — uses compiled .opencode/agents/<name>.md
c2c start opencode -n my-instance -a my-role

# Poll until the instance is registered + alive (replaces the old
# `c2c_tmux.py wait-alive` helper, which no longer exists):
until c2c list --json | jq -e '.[] | select(.name=="my-instance" and .alive)' >/dev/null 2>&1; do
  sleep 1
done

# Verify it's up
c2c list | grep my-instance
```

### Direct CLI

```bash
# OpenCode
c2c start opencode -n my-instance -a my-role

# Claude Code (role compiled to .claude/agents/)
c2c start claude -n my-instance -a my-role

# Codex (role compiled to .codex/agents/)
c2c start codex -n my-instance -a my-role
```

**Note on flag syntax:** `-a` and `--agent` accept values with `=` or a space.
Both are equivalent:
```bash
-a my-role    # works
--agent=my-role  # works
--agent my-role  # works
```

If you see `unknown option --agent foo. Did you mean -a?`, the shell ate
the space — use `-a my-role` or `--agent=my-role` instead.

---

## §4. Verify the agent lives the role

```bash
# Check registration
c2c list | grep my-instance
# Expected: alive, pid=<N>

# Check alias matches
c2c whoami 2>&1 | grep alias
# Expected: alias matches what you set in frontmatter or the role name

# Verify role file was picked up by checking the compiled agent file
# matches what you expect for the client
cat .opencode/agents/my-role.md | head -15
```

From inside the session, the agent should be acting per the role body —
e.g. if the role says "You are a QA agent...", the agent responds as QA.

Send a DM to verify bidirectional messaging works:

```bash
# From another agent's session:
c2c send my-instance "hello from $(c2c whoami | grep alias | cut -d: -f2)"

# Or use tmux (drives keystrokes into the pane running the instance):
./scripts/c2c_tmux.py send my-instance "ping"
```

---

## §5. Stop the instance

```bash
# Clean stop (managed instances are stopped via `c2c stop`; the old
# `c2c_tmux.py stop` subcommand no longer exists):
c2c stop my-instance

# Verify it's gone
c2c list | grep my-instance  # should be empty
```

---

## Common errors

### `c2c: unknown option --agent foo. Did you mean -a?`

Shell ate a space in `--agent foo`. Use `-a foo` or `--agent=foo`.

### `error: unknown client: 'foo'`

The client name is wrong. Use one of: `claude`, `codex`, `codex-headless`,
`opencode`, `kimi`, `crush`.

### `c2c roles compile` says "done" but no files written

The role file path is wrong — check `.c2c/roles/<name>.md` exists and the
name matches exactly (case-sensitive).

### Agent launches but doesn't act the role

The compiled file may be stale. Re-compile:
```bash
c2c roles compile <name> --client all
```
Then restart the instance.

### `c2c start` refuses with "incompatible client"

The role's `compatible_clients` frontmatter doesn't include the client you're
trying to launch. Either add the client to `compatible_clients` in the role
file, or remove the `compatible_clients` restriction.

---

## Design notes

- Canonical role files (`.c2c/roles/*.md`) are the **source of truth**.
  Compiled outputs (`.opencode/agents/`, `.claude/agents/`, etc.) are
  **gitignored** — they are regenerated on every `c2c roles compile`.
- The OpenCode renderer strips `c2c:` frontmatter but keeps `opencode:`
  frontmatter intact.
- The Claude renderer comments out `c2c:` and strips `opencode:`.
- The Codex and Kimi renderers comment out `c2c:` and strip `opencode:`
  and `claude:`.
- Snippets from `include:` are inlined into every compiled output, so
  recovery instructions, team context, etc. appear in all client renders.
- `c2c agent new` creates the canonical role file; `c2c roles compile`
  produces all client renders from it. You always edit the canonical.