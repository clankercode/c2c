# RESULT — B180 monitor re-resolve after rename

**Branch:** `fix/bl-b180`  
**Worktree:** `/home/xertrov/src/c2c/.worktrees/bl-b180`  
**Bug:** `.backlog/bugs/B180-monitor-after-rename-re-resolv.todo`  
**Status:** fixed on branch (not merged; backlog not marked done)

## Problem

`c2c monitor` bound alias + relay peek keys once at startup. After
`c2c rename`, the running monitor kept filtering/signing/peeking as the
old alias until kill+restart.

## Fix

1. **Pure logic** (`ocaml/cli/c2c_monitor_logic.ml`)
   - `decide_identity_rebind` — rebind when this session’s registration
     alias changes; suppressed when `--alias` froze identity
   - `parse_alias_renamed_marker` — detect B140 archive marker
   - `relay_peek_key_after_rebind` — recompute `cli-<new>` / connector key

2. **Monitor command** (`ocaml/cli/c2c_monitor_cmd.ml`)
   - Live `my_alias_r` / `alias_source_r` / `relay_peek_r`
   - Rebind triggers: registry inotify, archive `alias_renamed` marker,
     2s background poll
   - On rebind: migrate per-alias lockfile, update include-self filter,
     re-arm relay peek target + signing alias (no process restart)
   - Emit `identity.changed` (JSON) / human rebind banner

3. **Tests** — 9 new unit tests under `identity-rebind-b180` (52 total green)

4. **Docs** — `docs/monitor-json-schema.md` documents `identity.changed`;
   monitor `--help` man page notes B180 behaviour

## Verification

- `dune build ./ocaml/cli/test_c2c_monitor_logic.exe ./ocaml/cli/c2c.exe` rc=0
- `test_c2c_monitor_logic.exe` — 52/52 pass
- Live smoke (temp broker):
  - start `monitor --json --no-relay` as `old-name-b180`
  - `c2c rename gk-black-b180`
  - monitor emitted `identity.changed` old→new within ~100ms (no restart)

## Review

- Self-review (PIRFL): goal-fit + edge cases; NDJSON emit serialized under
  `emit_mutex` after concurrency note
- External gpt-5.5 `ccc` review started but hit tool/timeout limits without
  a final PASS/FAIL artifact; static review + e2e smoke used instead

## Not done (by request)

- No merge to master
- Backlog item left `in_progress` / not `done`
- No `bl done`
