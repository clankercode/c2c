# B171: Claude `--agent` not found for c2c-compiled project agents

**Severity:** high (blocks named `c2c start claude -n …` / live Stop-hook dogfood)
**Status:** fixed (Claude_renderer non-empty description fallback)
**Related:** B162 (named Haiku retry could not launch)

## Symptom

```
scripts/c2c_tmux.py launch claude -n b162-haiku-retry … --model haiku
```

writes `.claude/agents/b162-haiku-retry.md` then invokes Claude with
`--agent b162-haiku-retry`. Claude 2.1.207 exits 1:

```
--agent 'b162-haiku-retry' not found. Available agents: claude, Explore, …
```

Unnamed `c2c start claude --model haiku` reaches the TUI.

## Root cause

Claude Code loads project agents from `.claude/agents/*.md` but **refuses
files whose frontmatter `description` is missing or empty** (also noted in
the binary's doctor text: "fails validation (e.g. missing `description`)
never loads").

`C2c_role.Claude_renderer` always emitted:

```yaml
description: ""
```

when the role left description blank (the default for `C2c_role.empty` and
many minimal role files). Filename/`name:` frontmatter alone is not enough.

## Proof

Against Claude Code 2.1.207:

| Agent file | `claude --agent …` |
|---|---|
| `description: ""` | not found |
| no `description` field | not found |
| `description: non-empty text` | loads (turn runs) |

After the fix, `c2c roles compile` of a blank-description role yields
`description: c2c managed agent <name>` and
`claude --agent b171-live-probe -p …` returned `B171_OK`.

## Fix

`Claude_renderer.description_for_claude`: if description is blank, fall back
to the role label (when it is not the default `subagent`), else
`c2c managed agent <name>`. Unit tests in `test_c2c_role.ml`.

## Non-causes

- Not a cwd/discovery path bug (project `.claude/agents/` is scanned).
- Not `--setting-sources`.
- Not the lock file beside the agent.
- Not model selection (`--model haiku` works without `--agent`).
