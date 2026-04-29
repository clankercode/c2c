# SUBAGENT-IN-PROGRESS — `c2c agent quota` design

**Owner:** cairn (subagent dispatched from coordinator1, 2026-04-29)
**Target:** `.collab/design/2026-04-29-quota-awareness-cairn.md` (~250 lines)
**ETA:** ~20 min

## Goal

Design a swarm-wide quota visibility surface — an agent (or coordinator)
can ask "how much quota does my session/swarm have left?" and get back
both per-alias and aggregate numbers. Today only the local statusline
script `cc-quota` answers per-Claude-instance; nothing aggregates.

## In progress

- [x] Read `scripts/cc-quota` — confirmed source is `~/.claude/sl_out/<uuid>/input.json`
- [x] Read `ocaml/cli/c2c_stats.ml` — already harvests sl_out for tokens; rate_limits next door but unused
- [x] Read `.collab/design/SPEC-agent-stats-command.md` — sibling, CLI-only, no MCP
- [x] Confirmed `server_info_lazy` in `c2c_mcp.ml:251` — natural surface to extend
- [ ] Draft design doc — proposed model, slice plan, swarm-aggregate views
- [ ] Cross-link `.collab/research/SUBAGENT-IN-PROGRESS-quota-awareness.md`
      → final design path on completion

## Key sources reviewed

- `/home/xertrov/src/c2c/scripts/cc-quota` (bash; jq over sl_out JSON)
- `/home/xertrov/src/c2c/ocaml/cli/c2c_stats.ml` (token harvest, sl_out scan)
- `/home/xertrov/src/c2c/.collab/design/SPEC-agent-stats-command.md`
- `/home/xertrov/src/c2c/ocaml/c2c_mcp.ml:251` (`server_info_lazy`)

## On completion

Promote to `.collab/design/2026-04-29-quota-awareness-cairn.md`, then
either delete this stub or rename to `SUBAGENT-DONE-...` and link from
the design doc footer.
