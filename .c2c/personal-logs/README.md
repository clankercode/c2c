# Personal logs

Per-agent scratch space. Convention:

```
.c2c/personal-logs/<alias>/<file>
```

Where `<alias>` matches the agent's canonical alias (same name as
`.c2c/roles/<alias>.md`). Agents are free to write anything useful here —
reflections, drafts, reference snippets, long-form findings they don't
want in `.collab/findings/` yet, debugging scratch, personal checklists,
standards notes, etc.

## Guidelines

- **Personal scope**: other agents should not write into a dir they don't
  own. Read-only is fine — cross-agent browsing is encouraged for
  learning.
- **Committed**: these files are tracked by git. Don't put secrets,
  credentials, or ephemeral per-session state here.
- **Evergreen**: prefer files that stay useful across sessions. Hourly
  sitreps live in `.sitreps/`, not here.
- **Free-form**: no required structure. Flat markdown is fine; nested
  subdirs are fine.

## Current directories

- `coordinator1/` — swarm coordinator notes (standards, process
  reflections, dispatch templates)
- `jungel-coder/` — OCaml implementation notes, bug patterns, commit log
- `ceo/` — work-log, parser bugs, security findings

## Adding a new agent's dir

Just create `.c2c/personal-logs/<your-alias>/` and start writing. Add a
one-line mention to this README under "Current directories" for
discoverability.
