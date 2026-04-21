---
author: planner1
ts: 2026-04-21T19:00:00Z
severity: medium
status: FIXED — c9ddf52, 6ec97b6 (2026-04-21)
---

# `c2c install opencode` Overwrites Shared Project `.opencode/opencode.json`

## Symptom

When `fresh-oc` ran `c2c install opencode` from inside `/home/xertrov/src/c2c`,
it overwrote `.opencode/opencode.json` (the project-level MCP config) with their
session ID (`C2C_MCP_SESSION_ID=fresh-oc`, `C2C_MCP_AUTO_REGISTER_ALIAS=fresh-oc`),
replacing the existing `C2C_MCP_SESSION_ID=opencode-c2c` (planner1's session).

The file was also re-formatted to compact JSON (no indentation), losing the
human-readable format.

## Root Cause

`c2c configure opencode` / `c2c install opencode` writes `C2C_MCP_SESSION_ID`
to the project-level `.opencode/opencode.json`. But this file is:
1. Tracked in git — other agents' committed config lives there.
2. Shared across all OpenCode sessions running in the repo directory.

A session-specific value (`SESSION_ID`) should NOT live in a shared project file.

## Impact

- planner1's MCP config was overwritten (restored via `git checkout HEAD`).
- Next OpenCode session in this repo would have used `fresh-oc` as session ID
  even though it belongs to a different instance.
- Two concurrent OpenCode sessions in the same repo would conflict on session ID.

## Root Fix Needed

Option A: Write `C2C_MCP_SESSION_ID` to the **user-level** config
(`~/.config/opencode/opencode.json`) instead of project-level, so it doesn't
affect other users/sessions in the same repo.

Option B: Skip writing `C2C_MCP_SESSION_ID` to project config entirely — use
only `C2C_MCP_AUTO_REGISTER_ALIAS` (which can be the same for all sessions
of the same agent persona).

Option C: Lock the project-level config if it already has a valid session ID
(prompt or `--force` to overwrite).

## Immediate Mitigation

- Restored `.opencode/opencode.json` via `git checkout HEAD`.
- Agents running `c2c install opencode` in a shared repo should be aware of this.

## Lesson

`c2c install opencode` is not safe to run if another agent's project-level
config is already in place. Check git status of `.opencode/opencode.json` before
running install. Alternatively, use `--user` / user-level config path.

## Fix Applied (2026-04-21, planner1)

**Root fix: Option B implemented** — `C2C_MCP_SESSION_ID` removed from shared
project `opencode.json` (both Python and OCaml configure paths). The broker
now derives `session_id = alias` when `C2C_MCP_SESSION_ID` env is absent
(`derived_session_id_from_alias`), consistent with what the plugin reads from
the sidecar.

For managed sessions (`c2c start opencode`): session_id comes from env
inheritance (`build_env` sets `C2C_MCP_SESSION_ID=<instance-name>`) — no
derivation needed.

For non-managed sessions (plain opencode): session_id = alias (same as
sidecar's session_id from `c2c install`) — consistent.

Commits: c9ddf52, 6ec97b6, 1f8e9cb.
