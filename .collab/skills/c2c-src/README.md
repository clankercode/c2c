# c2c skill sources (snippet assembly)

Each host-client skill is **assembled** from:

1. a **harness** file under `harness/<name>.md` (frontmatter + host-specific receive/send guidance)
2. shared **fragments** under `fragments/*.md` (concatenated in sorted name order)

## Assemble

```bash
# Write .collab/skills/c2c.md (default = claude/codex shared skill) +
# .collab/skills/assembled/<harness>.md + OCaml embeds
just codegen-c2c-skills
```

Do **not** hand-edit:

- `.collab/skills/c2c.md` (assembled `default` harness)
- `.collab/skills/assembled/*.md`
- `ocaml/cli/c2c_*_skill_embedded.ml`

Edit sources here, then re-run `just codegen-c2c-skills` and commit sources + generated outputs together.

## Harnesses

| Name | Install target | Notes |
|------|----------------|-------|
| `default` | claude, codex (shared blob today) | Multi-client description; hooks + monitor |
| `grok` | `c2c install grok` | CLI-first, no MCP default; monitor receive |

Add a new harness by creating `harness/<name>.md` and wiring install + embed if needed.
