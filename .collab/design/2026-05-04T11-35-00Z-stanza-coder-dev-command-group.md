# Design: `c2c dev` command group

**Author:** stanza-coder  
**Date:** 2026-05-04  
**Status:** DRAFT — awaiting Max go/no-go  
**Ticket:** n/a (Max floated idea, coordinator1 greenlit design doc)

---

## Motivation

`c2c --help` currently lists ~60 commands at the top level. Many are
swarm-operator / developer internals that a regular user (or a freshly
spawned agent) never needs. Grouping these under a parent command
(`c2c dev`) cleans the default `--help` surface and makes the tool
more approachable.

## Name candidates

| Name | Pros | Cons |
|------|------|------|
| `c2c dev` | Short, obvious, matches `git stash`, `docker compose` | Could clash if we ever have a "dev mode" flag |
| `c2c ops` | Clear "operator" framing | Less intuitive for agents doing swarm dev |
| `c2c internal` | Unambiguous | Verbose, 8 chars |
| `c2c swarm` | Fits the domain | Might want `swarm` for user-facing room/topology commands |

**Recommendation:** `c2c dev` — short, clear, no realistic clash risk.

## Commands to migrate

Based on current tier system and usage patterns:

### Tier 3-4 (strong candidates — hidden from agents already)

| Command | Current tier | Notes |
|---------|-------------|-------|
| `sweep` | T3 | Dangerous during active swarm |
| `sweep-dryrun` | T3 | Preview companion to sweep |
| `commands` | T3 | Meta-command listing |
| `completion` | T3 | Shell completion generator |
| `install` | T3 | System setup |
| `mesh` | T4 | Internal plumbing |
| `relay-pins` | T3 | Operator TOFU management |
| `migrate-broker` | T3 | One-time migration |
| `registry-prune` | T3 | Test cleanup |

### Tier 2 (moderate candidates — operator lifecycle)

| Command | Current tier | Migrate? | Notes |
|---------|-------------|----------|-------|
| `sitrep` | T2 | YES | Coordinator-only |
| `worktree` | T2 | YES | Dev workflow only |
| `peer-pass` | T2 | YES | Review workflow |
| `coord-cherry-pick` | T2 | YES | Coordinator-only |
| `approval-*` (gc, list, pending-write, reply, show) | T2 | YES | Permission flow internals |
| `authorize` | T2 | YES | Alias for approval-reply |
| `resolve-authorizer` | T2 | YES | Permission plumbing |
| `sticker` | T2 | NO | Fun/social, user-facing |
| `memory` | T2 | NO | Agent-facing |
| `schedule` | T2 | NO | Agent-facing (native wake) |
| `stats` | T2 | MAYBE | Useful for agents too |
| `roles` | T2 | NO | Agent-facing (role mgmt) |
| `agent` | T2 | NO | Agent-facing |

### Tier 1 (keep at top level)

All Tier 1 commands stay: `send`, `list`, `whoami`, `poll-inbox`,
`peek-inbox`, `send-all`, `history`, `health`, `rooms`, `register`,
`doctor`, `monitor`, `screen`, etc.

## Backward compatibility

### Option A: Aliases with deprecation warnings (recommended)

Old names remain as top-level commands but print a stderr deprecation
warning on first use:

```
$ c2c sweep --force
[DEPRECATED] c2c sweep is now c2c dev sweep. Updating in 2 releases.
```

Implementation: in `c2c.ml`, register both the old top-level command
and the `dev` subcommand. The old registration wraps the same handler
with a `Printf.eprintf` prefix. No behavior change.

Timeline: deprecation warnings for 2 release cycles, then remove
the top-level aliases.

### Option B: Silent aliases (simpler, less disruptive)

Old names silently dispatch to `c2c dev <name>`. No warnings. Never
removed — just undocumented. Similar to how `c2c room` is an alias
for `c2c rooms`.

### Option C: Hard break (not recommended)

Remove old names immediately. Breaks existing role files, scripts,
runbooks.

**Recommendation:** Option A for Tier 3-4 commands (operators adapt
fast). Option B for Tier 2 commands (role files reference them, and
agents can't update themselves).

## Tier interaction

- `c2c dev` itself: **Tier 2** (lifecycle/setup). Visible to agents
  but clearly labeled as advanced.
- Subcommands inherit parent tier: the `dev` group is Tier 2, so
  all subcommands within it are at least Tier 2.
- Tier 3-4 subcommands within `dev` remain hidden from agent sessions
  via the existing `filter_commands` logic (filter applies to
  subcommand names within the group).

**Note:** Current tier filter is top-level only (per CLAUDE.md
architecture notes). To hide Tier 3-4 subcommands within `dev`, we'd
need to extend `filter_commands` to recurse into command groups. This
is a small addition but should be scoped explicitly.

## Implementation sketch

In `c2c.ml`:

```ocaml
(* 1. Define dev_group as a Cmdliner.Cmd.group *)
let dev_group =
  let info = Cmd.info "dev"
    ~doc:"Developer/operator commands (swarm internals)" in
  Cmd.group info [
    sweep_cmd;
    sweep_dryrun_cmd;
    sitrep_cmd;
    worktree_cmd;
    peer_pass_cmd;
    coord_cherry_pick_cmd;
    approval_gc_cmd;
    approval_list_cmd;
    approval_pending_write_cmd;
    approval_reply_cmd;
    approval_show_cmd;
    authorize_cmd;
    resolve_authorizer_cmd;
    registry_prune_cmd;
    relay_pins_cmd;
    migrate_broker_cmd;
    commands_cmd;
    completion_cmd;
    install_cmd;
    mesh_cmd;
  ]

(* 2. Add dev_group to main command list *)
(* 3. Keep deprecated aliases at top level with warning wrapper *)
```

The `Cmd.group` Cmdliner API handles subcommand dispatch, `--help`
generation, and error handling automatically.

## Migration checklist

- [ ] Create `dev` command group in `c2c.ml`
- [ ] Move command definitions (keep same implementations)
- [ ] Add deprecation-warning wrapper for old top-level aliases
- [ ] Update `filter_commands` to recurse into groups (for tier hiding)
- [ ] Update `docs/commands.md` tier listing
- [ ] Update role files that reference moved commands
- [ ] Update `.collab/runbooks/` that reference moved commands
- [ ] Update CLAUDE.md tier documentation
- [ ] Test: `c2c dev --help` shows grouped commands
- [ ] Test: `c2c sweep` still works (with warning)
- [ ] Test: agent session hides Tier 3+ subcommands within `dev`

## Open questions

1. Should `c2c dev` have a default action (e.g., show subcommand list)?
   Cmdliner groups default to showing help, which is fine.

2. Should we split further? E.g., `c2c dev approval` as a sub-group
   within `dev` for the 5 approval commands? Probably yes — that's
   already a natural cluster.

3. Does `c2c git` (the attribution shim) belong under `dev`? It's
   Tier 4 plumbing, but it's invoked via PATH shim, not directly.
   Probably leave it — it's not a user-typed command.

4. `c2c install` — this is Tier 3 but arguably user-facing (first-time
   setup). Could stay top-level with the others migrating. Discuss.

## Risk

Low. This is a refactor of command registration, not behavior. The
actual handler implementations don't change. Backward compat via
aliases means nothing breaks. Main risk is incomplete alias coverage
in role files/runbooks — the docs audit (#754) already mapped all
command references, so we have the inventory.
