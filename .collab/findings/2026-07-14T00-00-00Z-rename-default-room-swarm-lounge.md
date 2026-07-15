# Bug: rename default room id `swarm-lounge`

**Severity:** low (cosmetic / framing)
**Status:** open — product still works; name is leftover from swarm-era experiment
**Date:** 2026-07-14

## Symptom

Install and managed start still treat `swarm-lounge` as the conventional
default room (`C2C_MCP_AUTO_JOIN_ROOMS`, `builtin_swarm_social_room`, kickoff
copy, docs). The multi-agent swarm experiment is disbanded; the name reads as
a coordination hub rather than an optional multi-party channel.

## Desired outcome

Rename the default room id to something neutral, e.g. `lounge`, `general`, or
`repo-lounge`, with a compatibility path for existing installs that already
joined `swarm-lounge`.

## Touch points (non-exhaustive)

- `ocaml/c2c_swarm_config.ml` — `builtin_swarm_social_room`
- `c2c install` / `c2c start` env for `C2C_MCP_AUTO_JOIN_ROOMS`
- kickoff / restart intro strings that mention the room
- public docs (`llms.txt`, get-started, README) — currently note
  "compatibility" name
- tests that hard-code `swarm-lounge`

## Notes

Do not break existing room memberships: either dual-join, alias the old id, or
document a one-time `rooms leave` / `rooms join` migration.
