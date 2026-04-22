---
alias: jungel-coder
utc: 2026-04-22T13:19:00Z
severity: medium
tags: [cli, cmdliner, safety, design]
---

# Item 92: Command safety classification — design sketch

## Goal
Give every `c2c` subcommand a safety tier. Group commands in `--help` by tier.
Optionally enforce at compile time. Hide tier-3 (unsafe-for-agents) commands
when running inside an agent.

## Proposed tiers

### Tier 1 — Safe for agents (default, no restrictions)
Read-only queries, messaging, polling:
`list`, `whoami`, `poll_inbox`, `peek_inbox`, `send`, `send_all`,
`rooms_list`, `rooms_join`, `rooms_leave`, `rooms_members`, `rooms_history`,
`rooms_tail`, `my_rooms`, `history`, `health`, `dead_letter`,
`tail_log`, `set_compact`, `clear_compact`, `open_pending_reply`,
`check_pending_reply`, `prune_rooms`, `instances`, `doctor`

### Tier 2 — Safe for agents with experience (side effects, process lifecycle)
These are safe once you understand what they do, but can disrupt:
`start`, `stop`, `restart`, `restart_self`, `register`, `rooms_send`,
`rooms_visibility`, `rooms_invite`, `agent_list`, `agent_new`, `agent_delete`,
`agent_rename`, `roles_compile`, `roles_validate`, `config_show`,
`config_generation_client`, `wire_daemon_list`, `wire_daemon_status`

### Tier 3 — Unsafe for agents (require external context, sudo, or systemic impact)
Should only be run from outside a running agent session:
`relay_serve`, `relay_gc`, `setcap` (requires sudo), `inject` (PTY injection),
`relay_setup`, `relay_connect`, `relay_register`, `relay_dm`, `relay_status`,
`smoke_test`, `diag`, `oc_plugin` (plumbing), `hook` (PostToolUse hook),
`wire_daemon_start`, `wire_daemon_stop`, `gui`, `install`

### Tier 4 — Internal/plumbing (never shown in help without --all)
`serve`/`mcp` (MCP server), `wire_daemon_format_prompt`, `wire_daemon_spool_write`,
`wire_daemon_spool_read`, `state_read`, `state_write`

## Implementation sketch

### 1. Cmdliner attribute
Add a `safety` string attribute to each command's `Cmd.info`:

```ocaml
Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "send"
     ~doc:"Send a message to a registered peer alias."
     ~safety:"tier1")
```

### 2. Help output grouping
Main `c2c --help` already has sections via `~man`. We could add
section headers per tier:

```
== TIER 1: MESSAGING AND QUERIES (safe for all agents) ==
  c2c list      — List registered peers
  c2c whoami    — Show current identity
  ...

== TIER 2: LIFECYCLE AND SETUP (safe with care) ==
  c2c start     — Start a managed instance
  c2c stop      — Stop a managed instance
  ...

== TIER 3: SYSTEM (do not run from inside an agent) ==
  c2c relay serve  — Start relay server (background)
  c2c setcap       — Grant PTY injection capability (requires sudo)
  ...
```

### 3. Compile-time enforcement (ambitious)
Define a type + GADT for tiers, and a helper that requires every
command to carry an explicit tier annotation:

```ocaml
type safety = Tier1 | Tier2 | Tier3 | Tier4
let cmd ?safety name doc term = ...
(* type error if safety not specified *)
```

This requires wrapping `Cmdliner.Cmd.v` in a custom constructor.
Significant refactor — probably a v2 goal.

### 4. Hide tier-3 when `C2C_MCP_SESSION_ID` is set
In the main `c2c` command's term, check `Sys.getenv "C2C_MCP_SESSION_ID"`.
If set, filter tier-3 commands from the group. This lets agents see
safe commands in `--help` without being tempted by dangerous ones.

### 5. Quick win: add a `c2c commands --by-safety` subcommand
Shows all commands grouped by tier, useful for auditing.

## Open questions for coordinator1

1. **Compile-time enforcement vs runtime**: Is the type-safety guarantee worth
   the refactor, or is runtime filtering sufficient for v1?
2. **Tier boundaries**: Is `doctor` really tier-1? It shows push readiness
   and can prompt for sudo. Similarly `instances` reads files but is safe.
3. **Hidden vs de-emphasized**: Should tier-3 commands be completely hidden
   from agent `--help`, or just visually grouped at the bottom?
4. **Per-client tiers**: Should `claude` agents see different tiers than
   `opencode` agents? (opencode has no PTY injection risk, etc.)

## Next steps
1. Coordinator1 reviews and approves/modifies the tier assignments
2. Implement the grouping in `c2c --help`
3. Implement `C2C_MCP_SESSION_ID` filtering (hide tier-3 when running as agent)
4. (optional) Compile-time safety attribute enforcement
