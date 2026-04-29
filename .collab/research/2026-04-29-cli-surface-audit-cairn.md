# c2c CLI surface audit — 2026-04-29

**Author**: Cairn-Vigil (coordinator1, audit hat)
**Scope**: top-level + first-level subcommands of `c2c`
**Method**: `c2c commands --all`, `c2c <cmd> --help=plain`, `all_cmds` in
`ocaml/cli/c2c.ml:9887`, fast-path tier tables in `c2c.ml:9536-9617`.
**Disposition**: survey only — no code changes proposed in this pass.

---

## 1. Inventory

Top-level commands registered in `all_cmds` (alphabetical). Tier from
`fast_path_commands` tables in `c2c.ml`. **U = unclassified** (in
`all_cmds` but missing from any tier table — `c2c commands` won't list it).

| # | Command | Tier | Group? | Status | Notes |
|--:|---------|:----:|:------:|--------|-------|
| 1 | `agent` (group) | 2 | Y | ACTIVE | `list/new/delete/rename/run/refine` |
| 2 | `cc-plugin` (group) | 4 | Y | ACTIVE | internal: `write-statefile` |
| 3 | `check-pending-reply` | 1 | N | ACTIVE | permission-prompt plumbing |
| 4 | `clear-compact` | 1 | N | ACTIVE | trivial flag flip |
| 5 | `commands` | — | N | ACTIVE | meta: prints this audit's source |
| 6 | `completion` | U | N | ACTIVE | shell completion; no help body |
| 7 | `config` (group) | 2 | Y | ACTIVE | `show / generation-client` only |
| 8 | `coord` (group) | U | Y | ACTIVE | `cherry-pick` only — coordinator helper |
| 9 | `dead-letter` | 1 | N | ACTIVE | viewer |
| 10 | `debug` (group) | U | Y | ACTIVE | `statefile-checkpoint / statefile-log` |
| 11 | `diag` | 3 | N | ACTIVE | per-instance diagnostics |
| 12 | `doctor` (group) | 1 | Y | ACTIVE | health + push-readiness + drift checks |
| 13 | `gui` | 3 | N | ACTIVE | TUI launcher |
| 14 | `git` | U | N | ACTIVE | thin pass-through to `git` (?) |
| 15 | `get-tmux-location` | 2 | N | ACTIVE | tiny helper, awkward at top level |
| 16 | `health` | 1 | N | ACTIVE | broker diagnostics |
| 17 | `history` | 1 | N | ACTIVE | archived inbox viewer |
| 18 | `hook` | 3 | N | ACTIVE | PostToolUse hook entry |
| 19 | `init` | 3 | N | ACTIVE | **misclassified** — see §3 |
| 20 | `inject` | 3 | N | DEPRECATED | doc says deprecated; still exposed |
| 21 | `install` (group) | 3 | Y | ACTIVE | per-client + `all`, `self`, `git-hook` |
| 22 | `instances` | 1 | N | ACTIVE | overlaps with `list`/`status` (see §3) |
| 23 | `list` | 1 | N | ACTIVE | peer registry |
| 24 | `mcp` | 4 | N | ACTIVE | alias for `serve` (DUP) |
| 25 | `memory` (group) | U | Y | ACTIVE | `list/read/write/delete/share/...` |
| 26 | `migrate-broker` | U | N | ACTIVE | one-shot migration; tier-3-ish |
| 27 | `monitor` | U | N | ACTIVE | rich flags (`--all`, `--archive`, ...) |
| 28 | `my-rooms` | 1 | N | ACTIVE | thin alias for `rooms list --mine` |
| 29 | `oc-plugin` (group) | 4 | Y | ACTIVE | OpenCode-side plumbing |
| 30 | `open-pending-reply` | 1 | N | ACTIVE | permission plumbing |
| 31 | `peek-inbox` | 1 | N | ACTIVE | overlaps with `poll-inbox --peek` |
| 32 | `peer-pass` (group) | U | Y | ACTIVE | `sign/verify/send/list/clean` |
| 33 | `poll-inbox` | 1 | N | ACTIVE | also has `--peek` flag |
| 34 | `prune-rooms` | 1 | N | ACTIVE | scope-creep at tier 1 |
| 35 | `refresh-peer` | 4 | N | ACTIVE | listed tier-4; rare |
| 36 | `register` | 2 | N | ACTIVE | |
| 37 | `relay` (group) | 3 | Y | ACTIVE | sprawling subtree (see below) |
| 38 | `repo` (group) | 4 | Y | ACTIVE | per-repo config; only `set/show` |
| 39 | `reset-thread` | 2 | N | ACTIVE | codex-only; awkward at top level |
| 40 | `restart` | 2 | N | ACTIVE | |
| 41 | `restart-self` | U | N | DEPRECATED | runbook says use `c2c restart`; binary still on |
| 42 | `roles` (group) | 2 | Y | ACTIVE | overlaps with `agent` (see §3) |
| 43 | `rooms` (group) | mixed | Y | ACTIVE | tier-1 verbs + tier-2 verbs interleaved |
| 44 | `screen` | U | N | ACTIVE | screen target resolver; opaque |
| 45 | `send` | 1 | N | ACTIVE | core |
| 46 | `send-all` | 1 | N | ACTIVE | broadcast |
| 47 | `serve` | 4 | N | ACTIVE | MCP server; alias = `mcp` |
| 48 | `set-compact` | 1 | N | ACTIVE | |
| 49 | `setcap` | 3 | N | ACTIVE | one-shot sudo helper |
| 50 | `sitrep` (group) | U | Y | ACTIVE | only `commit` subcommand |
| 51 | `skills` (group) | U | Y | ACTIVE | `list/serve` |
| 52 | `smoke-test` | 3 | N | ACTIVE | |
| 53 | `start` | 2 | N | ACTIVE | |
| 54 | `stats` | 1 | N | ACTIVE | |
| 55 | `statefile` | 4 | N | ACTIVE | low-level r/w |
| 56 | `status` | 1 | N | ACTIVE | overlaps `health/verify/doctor/list` |
| 57 | `sticker` (group) | U | Y | ACTIVE | `list/send/verify/wall` |
| 58 | `stop` | 2 | N | ACTIVE | |
| 59 | `supervisor` (group) | 4 | Y | EMPTY-HELP | no commands shown in help |
| 60 | `sweep` | U | N | ACTIVE | dangerous — see CLAUDE.md |
| 61 | `sweep-dryrun` | U | N | ACTIVE | could be `sweep --dry-run` |
| 62 | `tail-log` | 1 | N | ACTIVE | RPC log viewer |
| 63 | `verify` | 1 | N | ACTIVE | overlaps `status` |
| 64 | `whoami` | 1 | N | ACTIVE | |
| 65 | `wire-daemon` (group) | mixed | Y | ACTIVE | `list/status/start/stop` + diag siblings |
| 66 | `worktree` (group) | U | Y | ACTIVE | `list/start/setup/gc/prune/...` |

**Headcount**: 66 top-level entries; 23 are command groups (35%). Total
addressable verbs (top-level + first-level subcommand) ≈ **130** per
`c2c commands --all | wc -l`.

**Unclassified count**: 17 of 66 top-level commands have no entry in any
of the four tier tables in `fast_path_commands`. They build, register,
and run — but `c2c commands` won't show them. Bug, not a feature.

---

## 2. Tier distribution

| Tier | In tables | Notable absentees |
|------|----------:|-------------------|
| 1 (agent-safe) | 22 | — |
| 2 (lifecycle)  | 21 | `peer-pass` (signing flow), `worktree`, `sitrep`, `coord` |
| 3 (operator)   | 19 | `migrate-broker`, `monitor`, `inject` shown but flagged DEPRECATED |
| 4 (internal)   | 12 | `repo`, `supervisor`, `statefile`, `mcp`, `serve` |
| **Unclassified** | **17 of 66 top-level cmds** | see Inventory `U` rows |

The `commands` printer makes a good faith claim ("here are all the
commands grouped by safety") that is **inaccurate**: a call to `c2c
commands --all` omits ~26% of registered top-level entries. Agents using
this output to decide what's safe will not see `monitor`, `peer-pass`,
`worktree`, etc.

---

## 3. Top 5 ergonomics issues

### 3.1 `c2c commands` is silently incomplete
The fast-path tables in `c2c.ml:9536-9617` are hand-curated and have
drifted from `all_cmds`. 17 top-level commands are not in any tier
table. Discovery suffers most where it matters: agents see the print as
authoritative and skip tools they could be using (e.g. `peer-pass`
during signed-PASS flows, `sticker`, `worktree`).

### 3.2 Five overlapping "is the swarm OK?" verbs
`status`, `verify`, `health`, `doctor`, `list -e/--all` all answer
flavours of the same question. From most-canonical to least, my best
guess at intended distinction:
- `doctor` — push-readiness, drift checks, recommendations
- `status` — compact swarm overview (what `whoami` + `list` would show together)
- `health` — broker plumbing diagnostics
- `verify` — count message exchanges (test-suite oriented)
- `list -e` — peers + last-seen

There is a real "five tools, one question" problem: a new agent does not
know which to reach for first. **`doctor` should subsume the others**, or
they should at minimum cross-link in their help text.

### 3.3 Inconsistent flag conventions
Surveyed across tier-1 commands:
- `--json` short form: `-j` on most, `--json` (no `-j`) on `doctor`,
  `memory`, `monitor` (uses bare `--json`).
- `--alias`: `-a, --alias` on `history`, `stats`, `memory`, `monitor`;
  `-F, --from` on `send`/`send-all`; bare `--from` on `monitor`.
  `register` and `whoami` don't take it. `install` reuses `-a, --alias`.
- `--limit`: `-l N` on `history`, `dead-letter`; `--limit` (no short) on
  `rooms history`, `debug statefile-log`.
- `--all`: a flag on `list`, `instances`; a value on
  `peer-pass revoke --all-targeted`; a *subcommand* on `install all`,
  `monitor --all`. Three meanings.
- Sub-commands sometimes drop `--help` body entirely (`rooms send`,
  `rooms invite`, `agent list`, `roles compile`, `wire-daemon list`).
  Cmdliner is generating only the synopsis line; help bodies are empty.

### 3.4 `peek-inbox` vs `poll-inbox --peek`
Two entry points for the same operation. `poll-inbox --peek` exists and
works. `peek-inbox` is a top-level alias. MCP also has both
`mcp__c2c__peek_inbox` and `mcp__c2c__poll_inbox`. Pick one path
canonically; deprecate the other.

### 3.5 `agent` and `roles` cover the same nouns
- `agent list/new/delete/rename/run/refine` — manages canonical role files.
- `roles compile/validate` — also operates on canonical role files.

The split is by verb-style ("agent" = lifecycle, "roles" = build), not
by domain. Newcomers reach for `c2c agent compile` and find nothing. They
should be a single group with all 8 verbs.

---

## 4. Consolidation proposals (3-5)

### 4.1 Fold `agent` + `roles` into a single `c2c role` group
```
c2c role list / new / delete / rename / run / refine / compile / validate
```
Plural-vs-singular noun choice resolved (singular wins; "the role file"
is the noun). Aliases `c2c agent` and `c2c roles` left in place for one
release with a deprecation warning. Saves a top-level slot, ends the
"which one?" friction.

### 4.2 Promote `doctor` as the umbrella for swarm-health
Make `doctor` the documented entry point. `status`, `health`, `verify`
remain as **`doctor` subcommands** (`doctor status`, `doctor health`,
`doctor verify`); top-level kept as aliases for one release.
`list -e/--enriched` stays put — it's the peer-table view, not a health
check.

Companion: each of `status`/`health`/`verify`'s help text should
already cross-reference `doctor`. Today none do.

### 4.3 Collapse `peek-inbox` into `poll-inbox --peek`
Drop top-level `peek-inbox`; remove `mcp__c2c__peek_inbox` (or make
it a thin alias that calls `poll_inbox` with `peek=true`). One verb,
one flag. Save the slot, remove the parallel-implementation drift
risk.

### 4.4 Merge `sweep` + `sweep-dryrun` into `sweep --dry-run`
Two top-level commands for one operation. Default to dry-run (`sweep`
prints "use --apply to actually do it"); `--apply` to commit. CLAUDE.md
already warns hard against `sweep` — making the safe path the default
de-foots the gun.

### 4.5 Move tier-4 plumbing under a single `c2c internal` group
`oc-plugin`, `cc-plugin`, `serve`, `mcp`, `statefile`, `refresh-peer`,
`supervisor`, `repo`, `wire-daemon spool-*`, `wire-daemon format-prompt`
are all internal/diagnostic. Group them under `c2c internal <subcmd>`.
Top level shrinks by ~10 entries; the agent-facing surface gets cleaner.
`mcp` as an alias for `serve` is doubly-redundant under this scheme.

---

## 5. Deprecation candidates

| Command | Why | Disposition |
|---------|-----|-------------|
| `inject` | doc string says "deprecated"; still on Cmdliner | Drop after one release; emit warning on invocation now |
| `mcp` | declared "alias for `serve`" — no semantic difference | Drop the alias; `serve` is the canonical name |
| `peek-inbox` (top-level) | duplicates `poll-inbox --peek` | Per §4.3 |
| `sweep-dryrun` | should be a flag on `sweep` | Per §4.4 |
| `restart-self` | runbook says use `c2c restart <name>`; legacy script in `deprecated/` | Remove from CLI |
| `migrate-broker` | one-shot helper for the legacy `<git-common-dir>/c2c/mcp` → `~/.c2c/repos/<fp>/broker` migration; most installs already migrated | Hide behind `--all`; remove next release |
| `get-tmux-location` | one-line helper, awkward at top level | Move to `internal` group or `doctor tmux` |
| `setcap` | one-shot setup; runs once per host | Move under `install` (`c2c install setcap`) |
| `screen` | help body absent; opaque purpose | Audit usage; if dead, remove |
| `git` | thin pass-through; CLAUDE.md says don't use it | Remove unless there's a load-bearing test |
| `supervisor` | `c2c supervisor --help` shows no commands at all | Either populate with the subcommands that exist or remove the group from `all_cmds` |
| `commands` (the verb itself) | broken (§3.1) without a sync mechanism | Fix or auto-derive from `all_cmds` |

The "broken `commands`" item is the most important on this list — it's
not deprecation, it's "the command lies to its callers right now."

---

## 6. Suggested next slices (not part of this audit)

1. **Auto-derive tier tables from a per-command annotation.** Each
   `Cmdliner.Cmd.t` carries a `~doc:` already; add a `~tier:` (or
   simpler: a parallel registry mapping name → tier) and have
   `commands_by_safety` consume it. Eliminates the drift class entirely.
2. **`role` group (§4.1)** — small, mechanical refactor; aliases let it
   ship without breaking peers.
3. **Help-body audit** — the empty-`COMMANDS-...-COMMON OPTIONS` blocks
   on `rooms send`, `agent *`, `roles *`, `wire-daemon *`, etc. are
   missing prose. Fix as a docs-hygiene slice.

---

## 7. References

- `ocaml/cli/c2c.ml:9887` — `let all_cmds = [ ... ]` (66 entries)
- `ocaml/cli/c2c.ml:9527-9617` — `fast_path_commands` (tier tables, 74 entries across 4 tiers)
- `ocaml/cli/c2c.ml:9622-9627` — tier label strings
- `CLAUDE.md` "Tier filter is top-level only" — confirms current enforcement model
- `c2c commands --all` — runtime view (130 lines incl. group headers)
