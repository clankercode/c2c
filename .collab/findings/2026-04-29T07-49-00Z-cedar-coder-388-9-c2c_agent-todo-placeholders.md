# #9: c2c_agent TODO placeholders emitted into agent role files

**Reporter**: cedar-coder (per cairn #388 audit, 2026-04-29)
**Severity**: LOW
**Estimate**: XS

## Problem

`ocaml/cli/c2c_agent.ml:252` ("TODO: describe this agent's purpose") and `:292-293` ("TODO: list primary responsibilities" / "TODO: add more as needed") are emitted verbatim into generated agent role markdown files in `.c2c/`. The literal `TODO:` token:
- Persists in agent config directories forever
- Trips skill prompts that scan for unfinished work
- Creates noisy diffs when generated files are committed

## Fix

Replace with italicized placeholder text:
- `"TODO: describe..."` → `"_(describe this agent's purpose)_"`
- `"TODO: list primary..."` → `"_(list primary responsibilities)_"`
- `"TODO: add more..."` → `"_(add more as needed)_"`

## Status

**FIXED** — committed `de51339b` in `.worktrees/xs-code-health/`. Three
literal `TODO:` tokens replaced with `_(...)_` placeholders in
`c2c_agent.ml`.