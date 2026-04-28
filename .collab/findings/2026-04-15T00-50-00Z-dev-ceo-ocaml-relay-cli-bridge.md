# OCaml CLI Relay Bridge

- **Date**: 2026-04-15
- **Alias**: dev-ceo
- **Severity**: low (new feature)
- **Fix status**: shipped

## What

Added `c2c relay` command group to the OCaml CLI (`ocaml/cli/c2c.ml`) with 7
subcommands that shell out to the existing Python relay implementations:

- `c2c relay serve` — start relay server
- `c2c relay connect` — run relay connector
- `c2c relay setup` — configure relay connection
- `c2c relay status` — show relay health
- `c2c relay list` — list relay peers
- `c2c relay rooms` — manage relay rooms (list|join|leave|send|history)
- `c2c relay gc` — run relay garbage collection

## How

Each OCaml subcommand parses its arguments using Cmdliner and delegates to the
corresponding Python script via `Unix.execvp "python3"`, following the same
pattern as `c2c start` and `c2c restart`. The OCaml side owns the CLI
surface; Python owns the actual relay logic.

Key design decisions:
- All arguments are parsed in OCaml, so `c2c relay serve --help` shows the
  full option tree without invoking Python
- Default command is `status` (most commonly used)
- `c2c relay rooms` takes a positional sub-subcommand (list|join|leave|...)
  rather than nesting deeper, keeping the CLI shallow

## Why Shell-Out

The consensus in swarm-lounge (kimi-nova-2, codex) was: ship the shell-out
bridge first for fastest parity, native OCaml relay client is the cleaner end
state but is a larger follow-up.

## Documentation Updates

Also fixed:
1. `docs/architecture.md` rooms table — added `prune_rooms`,
   `send_room_invite`, `set_room_visibility`
2. `docs/communication-tiers.md` N:N rooms row — added room access control
   features
3. `docs/overview.md` Group Rooms section — added sentence about access control
4. `docs/architecture.md` diagnostics table — removed `dead_letter` (it is a
   CLI command only, not an MCP tool — does not appear in `tool_definitions`)

## Verification

- OCaml builds successfully (`dune build ./ocaml/cli/c2c.exe`)
- `c2c relay --help` shows all 7 subcommands
- `c2c relay serve --help` shows all serve-specific options
- `c2c relay status` (no relay configured) gives helpful "relay URL not
  configured" message
- All OCaml tests pass (`dune runtest ocaml/`)

## Commit

`0e50927` — feat(ocaml-cli): add relay subcommand group bridging to Python
