# Agent Wizard — Design

**Date**: 2026-04-22
**Author**: coordinator1
**Status**: Draft, in-flight

## Purpose

`c2c agent new <name>` today takes a handful of flags and writes a minimal
commented template. Humans are left to fill the body themselves — which
produces inconsistent, often weak role files. The wizard replaces this
with a two-phase flow that produces high-quality, swarm-ready role files.

## Phases

### Phase 1 — Interactive CLI prompts

Runs in the caller's terminal. Structured, fast, deterministic. Questions:

- **name** — required positional arg (existing behavior; validated for
  filename chars + uniqueness under `.c2c/roles/`).
- **description** — one-sentence summary.
- **role type** — picker: `subagent` (default) | `primary` | `all`.
- **compatible_clients** — multi-select: `all` (default) | subset of
  `claude` `opencode` `codex` `kimi`.
- **theme** — picker from 11 curated themes, or skip.
- **snippets to include** — multi-select from `.c2c/snippets/*.md`.
- **auto_join_rooms** — text, default `swarm-lounge` for primaries,
  empty for subagents.

Outputs a **skeleton** `.c2c/roles/<name>.md` with filled frontmatter
and a placeholder body ("You are a <name> agent. TODO: describe
responsibilities.").

Non-interactive fallback: if any Phase 1 flag is passed (legacy
`--description`/`--role`/`--theme`), skip the prompts and use the
flag values — preserves scripting.

### Phase 2 — Chained generation-client handoff

After Phase 1 writes the skeleton, `c2c agent new` **auto-launches**
the user-preferred generation client (claude / opencode / codex —
configured via `c2c config`) with a pre-seeded prompt combining:

- The canonical role-designer persona (compile-time embedded, see
  "Role-designer source of truth" below).
- The current contents of `.c2c/roles/<name>.md`.
- Explicit instruction: "Interview the human and refine this file."

The generation client runs **directly, NOT via `c2c start`** — no
broker registration, no c2c plugin. It's a plain interactive session
whose only job is to produce the refined role file. When the human
says "done", the client is expected to save the file and exit.

## c2c config — generation-client preference

New command surface:

```
c2c config                         # show current config
c2c config generation-client       # show generation_client value
c2c config generation-client CLIENT  # set to claude|opencode|codex
c2c config --interactive           # interactive setup for all fields
```

Storage: `.c2c/config.toml` at repo root (per-repo). Minimal fields
today: `generation_client`. File format follows existing c2c TOML
conventions (codex config, etc).

On first `c2c agent new` without the field set, we prompt the user
inline and save.

## Role-designer source of truth

Canonical: `.c2c/roles/role-designer.md` (ceo-authored, 2026-04-22).

Build-time embed: `ocaml/cli/dune` adds a `(rule)` that reads
`.c2c/roles/role-designer.md` and generates
`ocaml/cli/role_designer_embedded.ml` with the file content as a
string constant. At runtime, `c2c agent new` prefers the on-disk
version if present, else falls back to the embedded one. This lets
the binary ship without the repo.

## Command-line launch recipes for Phase 2

| Client    | Invocation                                                    |
|-----------|---------------------------------------------------------------|
| claude    | `claude --append-system-prompt "$PROMPT"`                     |
| opencode  | `opencode run -p "$PROMPT"` (or equivalent interactive flag)  |
| codex     | `codex exec "$PROMPT"` (or interactive variant)               |

The wizard constructs `$PROMPT` from:
- Role-designer body (system prompt).
- A prelude: "We're creating a role named <name>. The skeleton is:
  <skeleton contents>. Interview me and refine the file in place."

Exact invocation flags TBD per client — will document once impl
confirms working shape.

## Implementation slices

1. **Config surface** (OCaml): `c2c config generation-client [VALUE]`
   — read/write `.c2c/config.toml`. (~100 LOC)
2. **Role-designer dune embed**: rule + generated module. (~20 LOC +
   a dune stanza)
3. **Phase 1 interactive prompts**: extend `agent_new_term` with a
   `-i`/`--interactive` flag (default on when TTY, off when flags
   passed). Prompt helpers shared across future interactive commands.
   (~150 LOC)
4. **Phase 2 chain**: launch generation client with pre-seeded
   prompt. Uses subprocess exec, doesn't wait for broker. (~80 LOC)

Total: ~350 LOC.

## Open questions

1. Do we want `c2c agent refine <name>` as a separate subcommand for
   re-running Phase 2 on an existing role file? (Probably yes — low
   marginal cost once Phase 2 exists.)
2. Should Phase 2 be skippable via `--no-refine`? (Default yes for
   `--interactive`; no for scripted use since Phase 2 requires a
   human.)
3. How does Phase 2 communicate the finalized file back to the
   wizard (if at all)? Options: file mtime poll, explicit `c2c
   agent finalize <name>` the refiner calls, or no callback (user
   just exits the refiner cleanly).

## Out of scope for v1

- Multi-human review (a committee mode).
- Version history / diffing across refine rounds.
- Non-file outputs (e.g. auto-push to GitHub).
