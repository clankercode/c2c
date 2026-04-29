# SPEC: #422 — decouple alias resolution from broker

## Problem

`resolve_alias_with_broker` in `c2c_rooms.ml` called `Broker.list_registrations broker`
unconditionally, even when `C2C_MCP_AUTO_REGISTER_ALIAS` is set. The env var path
was only tried as a fallback if the broker lookup returned nothing. This added
unnecessary IO in the common case.

## Goal

Extract a pure-env alias resolver for use as the fallback path, reducing broker
IO for the common case where the session is registered.

## Changes

### `ocaml/cli/c2c_utils.ml`

Added `alias_from_env_only () : string option` — pure env read, zero broker IO.

### `ocaml/cli/c2c_rooms.ml`

Refactored `resolve_alias_with_broker` to:
1. **session-id first** — broker lookup via `C2C_MCP_SESSION_ID` (preserves existing semantics)
2. **env fallback** — `C2c_utils.alias_from_env_only ()` if session not registered
3. error if neither resolves

Removed the local duplicate `env_auto_alias_rooms` function.

## Alias Resolution Priority (canonical)

```
override arg > session_id (C2C_MCP_SESSION_ID → broker) > env (C2C_MCP_AUTO_REGISTER_ALIAS)
```

## Acceptance Criteria

- [x] `alias_from_env_only` returns `Some` when `C2C_MCP_AUTO_REGISTER_ALIAS` is set and non-empty
- [x] `alias_from_env_only` returns `None` when unset or whitespace-only
- [x] `resolve_alias_with_broker` uses session-id resolution first, env fallback second
- [x] All existing unit tests pass (252 c2c_mcp + 12 worktree + 4 new utils)
- [x] No semantic change to rooms commands
- [ ] Peer-PASS (pending)

## Out of Scope

- `memory list/read` — already uses `resolve_alias_arg` (pure env)
- `worktree list/status` — already broker-free
- `c2c send` — already has `--from` override
