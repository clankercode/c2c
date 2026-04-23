# Role-Specific Rooms — Design Sketch

**Date:** 2026-04-23
**Author:** galaxy-coder
**Status:** Design sketch — for coordinator1 review

## Problem

Currently agents join `swarm-lounge` on startup. There's no per-role coordination channel. Max's idea: agents should also join a role-specific room (`#coders`, `#reviewers`, etc.) for targeted broadcasts and team coordination.

## Existing Infrastructure

- `c2c.auto_join_rooms: [room1, room2]` in role frontmatter — already supported
- `C2C_MCP_AUTO_JOIN_ROOMS` env var — drives startup auto-join
- `auto_join_rooms_startup` in `c2c_mcp.ml` — joins rooms listed in the env var
- `role_class:` field already exists in role files (e.g., `role_class: reviewer`)

## Approach

**Option A — Derive from `role_class` by convention:**

Define a naming convention: `role_class: reviewer` → auto-join room `#reviewers`. Pluralized, lowercase.

At `c2c start` or `c2c agent run`:
1. Read role file's `role_class`
2. Derive room ID: `String.lowercase_ascii(role_class) ^ "s"` (reviewer → reviewers)
3. Append to `C2C_MCP_AUTO_JOIN_ROOMS` alongside `swarm-lounge`

No new fields needed. Convention is discoverable.

**Option B — Explicit `role_room:` frontmatter:**

Add `c2c.role_room: <room-id>` to role file frontmatter. More explicit but requires users to know about the feature.

**Option C — Naming convention but opt-in:**

Same as A, but gated behind a flag or config (`C2C_AUTO_JOIN_ROLE_ROOM=1`). Default off to avoid surprise.

## Recommendation

**Option C** — naming convention (discoverable) but opt-in via `C2C_AUTO_JOIN_ROLE_ROOM=1` written by `c2c install <client>`. This matches how `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` was introduced — it was an opt-in written at install time, not a hard default.

Rationale: automatically joining a second room might surprise users who don't expect it. The opt-in makes the behavior visible and controllable.

## Implementation

1. **Role file parsing** (`c2c_role.ml`): `role_class` already parsed. Add optional `role_room` field, OR derive from `role_class` at the `c2c_start.ml` level.

2. **`build_env`** (`c2c_start.ml`): If `C2C_AUTO_JOIN_ROLE_ROOM=1` and role file has `role_class`, append `#{role_class}s` to `auto_join_rooms`.

3. **`c2c install <client>`**: Write `C2C_AUTO_JOIN_ROLE_ROOM=1` to the client's MCP env, alongside existing `swarm-lounge` auto-join.

4. **Backward compatibility**: Without the env var, behavior is unchanged (existing agents don't suddenly join new rooms).

## Open Questions

1. **Room must exist**: Should `c2c start` auto-create the role room if it doesn't exist? Or require rooms to be pre-created?
2. **Collision**: `role_class: coder` → `#coders`. What if `#coders` already exists as a different kind of room? (Rooms are just IDs, no type/scope enforcement.)
3. **Pluralization edge cases**: `role_class: security-review` → `#security-reviews`? Cleanest to just use `role_class` as-is, no pluralization: `role_class: reviewer` → `#reviewer`. Simpler.

## Files to Change

- `ocaml/cli/c2c.ml` — `c2c install <client>`: write `C2C_AUTO_JOIN_ROLE_ROOM=1`
- `ocaml/c2c_start.ml` — `build_env`: derive role room from `role_class` if env var set
- `ocaml/c2c_role.ml` — already parses `role_class`; add helper to get room ID
- Tests: add unit test for role_class → room derivation

## Scope

v1: opt-in naming convention, no new frontmatter fields, no auto-room-creation.
