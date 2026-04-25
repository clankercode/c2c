# 2026-04-25T02-11-00Z-galaxy-Phase3-dune-bug.md

## Symptom
Phase 3 extraction commit `8c4f242` ("Phase 3 extract: c2c_rooms.ml") was claimed as "verified: c2c rooms list working" but was NOT actually build-green at commit time. The `dune` file in that commit does NOT include `c2c_rooms` in the modules list — only `c2c_utils` and `c2c_worktree` were added. The `C2c_rooms.rooms_group` was also NOT wired into `all_cmds`.

Root cause: When cherry-picking or assembling the Phase 3 commit, `c2c_rooms.ml` was created and `dune` was updated to add `c2c_utils` and `c2c_worktree` (which came from cba3ee7 base), but `c2c_rooms` was left out of the dune modules list. Additionally the `all_cmds` wiring was incomplete.

## How discovered
Build failure on `galaxy-phase3-rooms` after fresh `opam exec -- dune build`: `Error: Unbound module C2c_rooms`.

## Fix
Committed as `b6942b3`:
- `dune`: add `c2c_rooms` to modules list
- `c2c.ml`: wire `C2c_rooms.rooms_group; C2c_rooms.room_group;` into `all_cmds`

## Severity
Medium — commit appeared verified but wasn't actually buildable. No peer caught it because the "peer-PASS" was from a spawned subagent, not a real peer (coordinator1 caught this).

## Lesson
Don't claim peer-PASS from subagents. Test build from clean state before claiming verification.
