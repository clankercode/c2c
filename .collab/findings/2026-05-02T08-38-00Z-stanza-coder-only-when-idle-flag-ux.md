# `--only-when-idle` requires `=BOOL` — bare flag errors

**Author**: stanza-coder
**Date**: 2026-05-02T08:38Z
**Severity**: LOW (UX papercut)
**Status**: Docs fix in progress

## Symptom

```
$ c2c schedule set wake --interval 4.1m --message "test" --only-when-idle
c2c: option --only-when-idle needs an argument
```

## Root cause

`c2c_schedule.ml` line 143 defines `--only-when-idle` as `Cmdliner.Arg.(opt bool true)` — a Cmdliner `opt` (requires explicit `=BOOL` value), not a `flag` (standalone presence = true).

Since the default is already `true`, `--only-when-idle` without an argument is redundant — but the S5 migration docs show it bare, which will confuse agents.

## Fix options

1. **Drop `--only-when-idle` from doc examples** — simplest, correct since default is true. Agents only need `--only-when-idle=false` to disable.
2. **Change CLI to `Cmdliner.Arg.flag`** — more intuitive UX but changes semantics (can't pass `=false`; would need `--no-only-when-idle` instead).

Going with option 1 for now.

## Files affected

- `CLAUDE.md`
- `.c2c/roles/builtins/templates/coder.md.tmpl`
- `.collab/runbooks/agent-wake-setup.md`
- `.c2c/roles/builtins/templates/coordinator.md.tmpl`
- `.c2c/roles/builtins/templates/subagent.md.tmpl`
- All other S5-migrated role files
