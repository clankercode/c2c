# SPEC: #422 — decouple alias resolution from broker

## Problem

`resolve_alias_with_broker` in `c2c_rooms.ml` unconditionally called
`Broker.list_registrations broker` even when `C2C_MCP_AUTO_REGISTER_ALIAS` is set,
adding unnecessary IO for the common case where the env var is present.

## Goal

Extract a pure-env alias resolver and use it as the fast-path in rooms
subcommands, falling back to broker lookup only when the env var is absent.

## Changes

1. **`ocaml/cli/c2c_utils.ml`**: added `alias_from_env_only () : string option`
   — pure env read, zero broker IO. Canonical home for this helper since
   both c2c.ml and c2c_rooms.ml already open `C2c_utils`.

2. **`ocaml/cli/c2c_rooms.ml`**: refactored `resolve_alias_with_broker` to:
   - first try `C2c_utils.alias_from_env_only ()` (fast-path, no IO)
   - only call `Broker.list_registrations broker` if env returns None
   - removed the local duplicate `env_auto_alias_rooms` function

3. **`ocaml/cli/c2c.ml`**: no change (alias_from_env_only already existed
   inline in resolve_alias; extracted to C2c_utils for sharing)

## Acceptance Criteria

- [x] `alias_from_env_only` returns `Some v` when `C2C_MCP_AUTO_REGISTER_ALIAS` is set
- [x] `alias_from_env_only` returns `None` when absent/empty
- [x] `resolve_alias_with_broker` calls broker ONLY when env returns None
- [x] All existing unit tests pass (252 c2c_mcp + 12 worktree + others)
- [x] No semantic change to any command
- [ ] Peer-PASS (pending)

## Out of Scope (already broker-free or env-only)

- `memory list/read` — already uses `resolve_alias_arg` (pure env)
- `worktree list/status` — already broker-free
- `c2c send` — already has `--from` override
