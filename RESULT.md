# RESULT — B181 relay connector: process alive but last-sync stale

**Branch:** `fix/bl-b181`  
**Status:** fixed (not merged; backlog item left in_progress / not `bl done`)

## Problem

`c2c whoami --relay` could report `registered_unreachable` (lease alive, no live
connector bridge) while a multi-hour `c2c relay connect` PID still existed and
`connector-state.json` `last_sync` was days old. Operators could not tell whether
to restart connect, re-register, or ignore. Root cause: process presence was
treated as bridge health in doctor paths, and whoami/status did not distinguish
wedged vs absent or give copy-paste recovery.

## Fix summary

1. **Bridge liveness = fresh successful sync (`last_ok`), not PID**
   - `Relay_doctor.connector_running` ignores process lists; requires fresh
     `last_sync` **and** `last_ok` within 120s.
2. **Doctor `relay.connector` diagnoses wedged connectors**
   - Process present + stale state → FAIL `"wedged; process≠bridge health"` with
     restart remediation (never PASS on PID alone).
3. **whoami/status connector object enriched (additive JSON)**
   - `live`, `state_file`, `last_sync_age_s`, `last_ok_age_s`,
     `process_present`, `health` (`ok|stale|wedged|erroring|starting|absent`),
     `remediation`.
4. **Broker-owned PID in `connector-state.json`**
   - Writers record `pid`; `connector_pid_alive` checks it so unscoped
     production argv (`c2c relay connect` without `--broker-root`) still
     surfaces process presence for wedged detection.
5. **Sync watchdog (loud fail)**
   - SIGALRM wall-clock cap per sync (`max(90s, 4×interval)`); 3 consecutive
     timeouts → exit 3 so managed restart can recover a hung connector.

## Tests

- `test_c2c_doctor_capabilities` — 25 OK (incl. B181 wedged branch)
- `test_c2c_relay_state` — 24 OK (incl. health/remediation + pid helper)
- `test_c2c_cli` — 175 OK
- `dune build --root .` clean for this worktree

## Files

- `ocaml/relay_doctor.ml`
- `ocaml/relay_state.ml` / `.mli`
- `ocaml/c2c_relay_connector.ml`
- `ocaml/cli/c2c_relay_state.ml`
- `ocaml/cli/c2c_doctor_relay.ml`
- `ocaml/test/test_c2c_doctor_capabilities.ml`
- `ocaml/test/test_c2c_relay_state.ml`
- `docs/commands.md`

## Commits / SHAs

| Role | SHA |
|------|-----|
| Fix commit | `d001d504e8c55403b3f76de4c9fe99d5d0f32710` (`d001d504`) |
| RESULT SHA note | `7a15d33e11add0fd8ac5a06242a4dbc37fc996d4` (`7a15d33e`) |
| Branch tip | `fix/bl-b181` @ `7a15d33e` |

Claim commit (pre-existing on branch history): see `git log --oneline` for `bl claim B181` if present; worktree started from claim already applied.

**Not done:** merge to master, `bl done`, push (per instructions).
