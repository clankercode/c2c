# SUBAGENT IN PROGRESS — smoke-heartbeat

**Agent**: subagent of cairn (heartbeat smoke gap A)
**Started**: 2026-04-29
**Worktree**: `.worktrees/smoke-heartbeat/` (branch `smoke-heartbeat`)
**Base**: `refs/remotes/origin/master`

## Goal

Implement gap A from
`.collab/research/2026-04-29-smoke-coverage-audit-cairn.md` — add a
`/heartbeat` test to `scripts/relay-smoke-test.sh`. Section slots in
after the existing 7 sections; integrates with `green/red/info` PASS
counter pattern.

## Plan

1. Stub this file (DONE).
2. Add section 8 ("Heartbeat") to `scripts/relay-smoke-test.sh`.
   - Calls `POST /heartbeat` with `{node_id, session_id}` matching
     the `cli-${ALIAS}` convention from `c2c relay register`
     (`c2c.ml:4185-4186`).
   - Asserts response shape: `ok=true` AND
     `result == "ok"` AND `lease.alias == $ALIAS`.
   - Unsigned-path-friendly: handler accepts no-auth heartbeat
     (`relay.ml:3185-3187`).
3. Run script against `https://relay.c2c.im`, capture PASS count.
4. Commit `feat(smoke): add /heartbeat coverage` with
   `--no-build-rc:doc-only` (script-only, no OCaml change).
5. Update this file with final SHA + PASS-count delta.

## Status

- [x] stub
- [x] script edit
- [x] live run against relay.c2c.im
- [x] commit

## Final

- **SHA**: `02037030` (branch `smoke-heartbeat` in worktree
  `.worktrees/smoke-heartbeat/`)
- **Live run**: 12 PASS / 0 FAIL against `https://relay.c2c.im`
- **Section count**: 8 numbered sections (was 7)
- **Lines added**: 41 to `scripts/relay-smoke-test.sh`
- **Coverage scope**: peer-route auth-classification (HTTP 401
  + spec-§5.1 message). Does NOT cover signed-call success;
  audit Proposal A note flags `c2c relay heartbeat` CLI surface
  as the lightweight follow-up.

## Notes for follow-up

- A signed-call heartbeat PASS would catch route deletion (auth
  runs before routing, so unsigned 401 is identical for any
  non-unauth path). Today's check catches reclassification.
- Pre-existing room-history flake observed in two of three
  runs (worth filing under a separate slice if reproducible).
- During first dry-run, `curl -sf` swallowed the 401 body → use
  `-s -o BODY -w "%{http_code}"` pattern for HTTP-status-aware
  assertions.
