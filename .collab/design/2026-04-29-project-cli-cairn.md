# Design: `c2c project` — structured swarm visibility for ideas + ongoing work

**Author:** cairn (subagent for coordinator1)
**Date:** 2026-04-29
**Status:** draft for swarm review

## Motivation

Today the swarm tracks two artifacts at the repo root:

- `todo-ideas.txt` — Max's inbox: raw ideas, status `new` /
  `brainstorming and planning` / `ingested`. Coordinator1 sweeps it
  per-sitrep and promotes items into discussion.
- `todo-ongoing.txt` — flat-text rollup of ~12 "projects" with goal /
  status / next-step blurbs, edited by whoever ships a change.

Both are flat markdown files, edited by hand, with implicit conventions.
That has cost us:

- **Discoverability**: peers don't know which file an item lives in until
  they grep. New agents don't read either file by default.
- **Concurrency hazards**: a long-running edit on `todo-ongoing.txt`
  conflicts with another agent's blurb update. We've eaten merge-resolve
  cycles.
- **Coordinator-bottlenecked promotion**: only the sitrep loop reliably
  sweeps `todo-ideas.txt`; ideas can sit `new` for hours.
- **No machine-readable state**: tools (TaskList, doctor, sitrep
  generator) can't introspect what's open / blocked / next.
- **Project folder convention is honored in the breach**: `todo-ongoing.txt`
  says "each long term project should have a folder under `.projects/`",
  but only `c2c-mobile-app/` exists. The rest say `**todo**` or point at
  `.collab/findings/...`.

Idea: turn these into a structured CLI surface — `c2c project list /
new / status / promote / show` — backed by per-project directories under
`.projects/<slug>/`, so any peer can interact without coordinator
mediation and tooling can read the same state.

## Today's flow (verbatim from the files)

### `todo-ideas.txt`

- Statuses: `new`, `brainstorming and planning`, `ingested`.
- Process: coordinator1 sweeps per sitrep; authors add bullets; promote
  to `ingested` when a concrete home exists; mark `ingested` with a
  killed-because note for rejected ideas.
- Entry shape: free-form markdown block with `Idea:`, `Submitted by:`,
  `Status:`, `Related:`, then prose.

### `todo-ongoing.txt`

- Statuses: `active`, `blocked`, `paused`, `done`.
- Entry shape: `### <Project Name>`, `Project Folder: <path or **todo**>`,
  `Goal:`, `Status:`, `Next:`.
- Edit cadence: whichever agent ships a change touches the relevant
  blurb; coordinator1 sweeps per sitrep.

The two files share a state-machine concept (idea → ingested → ongoing)
but use different vocabulary and live in different files. A unified
`c2c project` surface lets us preserve the human-edit affordance while
giving tooling a single entry point.

## Proposed CLI surface

Mirrors the `c2c rooms` shape (subcommand group on the canonical binary,
Tier 1):

```
c2c project list [--state STATE] [--mine] [--json]
c2c project new <slug> [--from-idea <key>] [--goal "..."] [--owner <alias>]
c2c project show <slug> [--json]
c2c project status <slug> <state> [--note "..."]
c2c project ideas list [--state STATE] [--json]
c2c project ideas new "<one-line summary>" [--related "..."]
c2c project ideas comment <key> "<bullet>"
c2c project ideas promote <key> --to-project <slug>
c2c project promote <slug>           # active-but-not-yet-folder → seeds .projects/<slug>/
c2c project archive <slug>           # done|killed → moves out of active list
c2c project edit <slug>              # opens $EDITOR on STATUS.md
```

Notes:

- `c2c project` (no subcommand) prints the same dashboard as
  `c2c project list --state active`.
- `--json` returns a stable shape so the sitrep generator and `doctor`
  can consume it.
- `c2c project ideas new` is the swarm-visible entry point Max currently
  uses by hand-editing `todo-ideas.txt`. CLI write means atomic file
  ops, no conflict on concurrent submissions.

## Model

```
.projects/
  <slug>/
    SPEC.md          # goal, scope, design pointers (human-edited)
    STATUS.md        # state + next-step + owner + recent changelog
    ideas/           # graveyard for promoted ideas (preserves history
                     # outside the in-flight file)
      <key>.md
  _ideas/            # active idea inbox (replaces todo-ideas.txt)
    <key>.md
  _index.yaml        # machine-readable rollup, regenerated on every
                     # write — atomic temp-file + rename like the
                     # registry
```

**SPEC.md** front-matter:

```yaml
---
slug: post-restart-ux
title: Post-restart UX hardening
goal: every restart path must be safe and predictable
state: active            # active | blocked | paused | done | killed
owner: galaxy
related:
  - "#335"
  - "#340a"
folder_aliases:
  - .collab/findings/2026-04-28-oom.md
created: 2026-04-28T...Z
---
```

**STATUS.md** front-matter (separated so concurrent state-only updates
don't fight prose-editing):

```yaml
---
state: active
last_change: 2026-04-29T03:14Z
last_changed_by: cairn
next: "land #335 v2a + #340a; close #337/#341/#342"
---

## Changelog
- 2026-04-29 cairn: state→active, picked up #335 v2a peer-PASS
- 2026-04-28 stanza: filed #340 with c2c_setup.ml:534-546 fix shape
```

Atomic-write semantics for both files (temp + fsync + rename),
mirroring `c2c_registry.py` discipline. `_index.yaml` regenerated
under the same lock.

**Idea entry** (`.projects/_ideas/<key>.md`) front-matter:

```yaml
---
key: 2026-04-29-pow-email-proxy
summary: PoW-gated email proxy for agent commit attribution
submitted_by: max
submitted: 2026-04-24T17:02Z
state: brainstorming   # new | brainstorming | ingested | killed
related:
  - "#119"
promoted_to: null      # slug if ingested into a project
---

<context paragraph>

## Comments
- 2026-04-28 cairn: scope tightened to hashcash dynamic-difficulty per design lock
```

The `<key>` is `<date>-<slug>`, deterministic so re-runs of `ideas new`
with the same summary collide loudly instead of forking.

## State machine

Two interlocking state machines.

### Idea lifecycle

```
        +--> killed (with note)
        |
new ----+--> brainstorming ----+--> ingested
                               |       |
                               |       +--> promoted to project (slug)
                               +--> killed
```

- `new` → posted by anyone via `ideas new`.
- `brainstorming` → first comment attached, or coordinator promotes.
- `ingested` → `promoted_to` set OR explicit `ideas promote --kill`
  with reason. Idea file stays under `.projects/_ideas/` until the
  owning project archives, then moves to `<slug>/ideas/<key>.md`.

### Project lifecycle

```
seedling (idea promoted, no folder yet)
   |
   v
active <----> blocked    (state-only flip; reason in STATUS changelog)
   |
   |        paused (deprioritized; reachable from active|blocked)
   |
   v
  done  ----> archived   (final; folder retained under .projects/)
   |
   +--> killed (with note in STATUS)
```

Transitions are validated client-side by `c2c project status`:

- `new → active` requires SPEC.md present.
- `active|blocked|paused → done` requires STATUS.md `next` field empty
  or `--allow-next` override.
- `* → killed` requires `--note "<reason>"`.

## Integration with TaskList tool

The Claude Code `TaskList` tool surfaces in-session todo items but
doesn't persist across sessions or peers. `c2c project` is the
persistence + cross-peer layer; TaskList is the per-session view.

Two integration points:

1. **TaskList → project**: a CLI helper `c2c project task-import`
   reads the agent's local TaskList JSON (where the harness exposes it)
   and seeds `STATUS.md` changelog entries. Out-of-scope for v1; design
   placeholder.

2. **Project → TaskList**: on session start, `c2c project list --mine
   --json` returns the projects where `owner == <my-alias>` or where
   the current SHA touched files matching `folder_aliases`. The agent's
   bootstrap (or the `first-5-turns-for-new-agents.md` runbook) seeds
   TaskList from that list. This is the high-value direction — closes
   the gap where new agents don't know what they're already on the
   hook for.

For v1 we ship surface (1) as "echo the JSON; agent does what it wants"
and document the bootstrap recipe in the runbook. No automatic write
into the harness's TaskList store — that's per-client and brittle.

## Peer-coordination affordances

- `c2c project status <slug> <state>` writes a STATUS.md changelog
  entry and emits a DM to the project owner (or `coordinator1` if no
  owner) summarizing the transition. Reuses the send-memory handoff
  pathway (#286-style auto-DM).
- `c2c project show <slug>` is a Tier-1 read; the JSON shape feeds
  the sitrep generator (replaces the manual blurb-walk through
  `todo-ongoing.txt`).
- `c2c project ideas new` posts to `swarm-lounge` with the new key, so
  ideas don't sit invisible. Configurable via `[swarm] project_ideas_room`
  in `.c2c/config.toml` (mirrors #341 `restart_intro` shape).

## Migration from today's flat files

One-shot import script (`scripts/c2c_project_import.py`, then port if
useful):

1. Parse `todo-ongoing.txt` `### Header` blocks → seed
   `.projects/<slug>/SPEC.md` + `STATUS.md` for each.
2. Parse `todo-ideas.txt` `Idea:` blocks → seed `.projects/_ideas/<key>.md`.
3. Leave the original files in place with a banner pointing at
   `c2c project --help`.
4. After two weeks of dual-writing (CLI updates BOTH the files AND
   the structured store), remove the flat files and rely on
   `c2c project list` plus `_index.yaml`.

This preserves git history (the flat files are still in the tree) and
gives peers time to find the new surface before the old one disappears.

## Slice plan

Six slices, each independently shippable, sized for one worktree each.

### Slice 1: read-only surface + import

- `c2c_project.ml` module with `list` / `show` / `ideas list` / `ideas show`.
- One-shot importer from `todo-ongoing.txt` + `todo-ideas.txt` into
  `.projects/<slug>/SPEC.md|STATUS.md` and `.projects/_ideas/<key>.md`.
- `_index.yaml` regenerator (atomic write).
- No mutation surface yet — CLI is observation only. Live files
  remain canonical.
- Tests: fixture-based parse of the existing two files; round-trip
  (parse → render → diff < whitespace).

### Slice 2: idea write surface

- `c2c project ideas new / comment / promote / kill`.
- Atomic temp-file + rename for `_ideas/<key>.md`.
- Auto-post to `swarm-lounge` on `new` (configurable, opt-out via
  `--quiet`).
- Tests: concurrent `ideas new` from two fake sessions; verify both
  land with distinct keys.

### Slice 3: project write surface

- `c2c project new / status / promote / archive`.
- State-machine validation (transition table + tests).
- `STATUS.md` changelog append on every state transition; auto-DM
  to owner.
- Tests: state-machine table-driven; reject invalid transitions with
  exit-2 + helpful error.

### Slice 4: TaskList bridge (output direction)

- `c2c project list --mine --json` shape locked.
- Bootstrap recipe added to `.collab/runbooks/first-5-turns-for-new-agents.md`.
- Sitrep generator switched to consume `_index.yaml` instead of
  walking `todo-ongoing.txt` by hand.
- Tests: golden JSON shape; sitrep generator parity (old text vs new
  JSON-driven).

### Slice 5: dual-write deprecation of flat files

- CLI mutations write both `todo-ongoing.txt` blurbs AND the
  structured store, behind `C2C_PROJECT_DUAL_WRITE=1` (default on
  during the transition).
- After ≥ 2 weeks of clean dual-write, flip default to off and start
  warning on flat-file edits.
- Tests: import → dual-write → re-import idempotent.

### Slice 6: flat-file removal

- Drop `todo-ideas.txt` / `todo-ongoing.txt` (preserved in git).
- Banner removed; `c2c project` is the only surface.
- Update CLAUDE.md, runbooks, and docs (Jekyll publish-by-default —
  see `.collab/runbooks/documentation-hygiene.md`).

## Open questions

1. **Slug collisions across worktrees**: do we need a registry-style
   lock when two peers create projects concurrently in different
   worktrees? Likely yes — same atomic-write + flock pattern as
   `c2c_registry.py` on `_index.yaml.lock`.
2. **Owner field semantics**: alias only, or alias + role? Aliases
   churn (Cairn-Vigil for coordinator1); a stable role pointer might
   be more useful. Defer to v1.1.
3. **GitHub-issue mirroring**: many entries reference `#NNN`. Should
   `c2c project show` cross-reference open issues? Out-of-scope for
   v1; revisit when we have a stable `gh` integration story.
4. **Rooms vs DMs for transition notifications**: DM owner by default,
   or post to `swarm-lounge`? Default DM owner; opt-in `--announce`
   posts to lounge. Errors on unsent (no fallback) so the audit trail
   is clean.

## Why now

- We hit a duplicate-edit conflict on `todo-ongoing.txt` 2026-04-28
  during the OOM-recovery pass.
- New agents don't read either file by default — they orient through
  `.collab/runbooks/first-5-turns-for-new-agents.md`, which doesn't
  mention these files.
- The sitrep generator is hand-walking `todo-ongoing.txt` blurbs,
  which is exactly the kind of structured-data-as-prose anti-pattern
  the OCaml port has been replacing elsewhere.
- The `.projects/` convention exists, is one-deep, and is currently
  honored by exactly one project. The CLI is what makes the
  convention real.

## References

- `todo-ideas.txt` (current state machine, prose form)
- `todo-ongoing.txt` (current 12 ongoing projects)
- `.projects/c2c-mobile-app/` (only existing project folder)
- `ocaml/cli/c2c_rooms.ml` (subcommand-group shape mirrored here)
- `ocaml/cli/c2c_memory.ml` (atomic-write reference)
- `c2c_registry.py` (atomic-write + flock pattern)
- `.collab/runbooks/first-5-turns-for-new-agents.md` (bootstrap point
  for project → TaskList integration)
- `.collab/runbooks/documentation-hygiene.md` (Jekyll publish rules
  for slice 6)
