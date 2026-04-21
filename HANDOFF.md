# HANDOFF — coordinator1 session, 2026-04-21

## Context

Coordinator session running a dynamic `/loop` to drive swarm toward
unifying Claude Code, Codex, and OpenCode via c2c. Ran in parallel with
a Ralph loop (completion promise `OC_Q_E2E_TESTED`) that targets
fixing the OpenCode plugin for v2 and E2E-testing it from scratch.

Queued commits ahead of `origin/master`: **140**. No push performed
(per `CLAUDE.md` policy — coordinator1 is the push gate; analysis shows
no relay-server code changed, so deploy is not warranted).

## Primary work thread — OpenCode plugin v2

The OpenCode TUI auto-focus / session-kickoff path went through a long
cascade of fixes this session. End state: **#58 TUI focus validated,
session cross-contamination resolved, resume-env propagation fixed,
E2E tests landed.**

### Commits landed (session-attributable)

| SHA       | Author          | Subject                                                               |
|-----------|-----------------|-----------------------------------------------------------------------|
| a37b35d   | (earlier)       | Instance lock — POSIX lockf on `outer.pid` + registry precheck        |
| 7667564   | coordinator1    | Drop broken `c2c-tui.ts`, drive TUI focus via `/tui/publish` POST     |
| 911c0b2   | coordinator1    | Propagate `-s ses_*` to plugin via `C2C_OPENCODE_SESSION_ID`          |
| 014a295   | (peer)          | Cold-boot exponential-backoff retry for `promptAsync`                  |
| ddb81ba   | fresh-oc        | Replace fetch(serverUrl) with `ctx.client.tui.publish()` SDK call      |
| 0648a87   | fresh-oc        | Fix `build_env` duplicate-key bug (filter-then-append)                |
| 7e9d9cc   | coder2-expert   | `C2C_CLI_COMMAND` absolute path (fork-bomb prevention)                |
| d4be551 … 89c0e36 | fresh-oc | Regression tests for 911c0b2 + 0648a87                                |
| c2f86e4   | fresh-oc        | Live E2E: `C2C_TEST_RESUME_E2E=1 C2C_TEST_RESUME_SESSION_ID=ses_*`    |
| 31dcb7b   | fresh-oc        | Findings doc: OpenCode plugin v2 architecture                          |

### Root-cause chain (in order discovered)

1. **Cross-session contamination** — `bootstrapRootSession()` picked
   `roots[0]` from app-wide `ctx.client.session.list()`, so two parallel
   `c2c start opencode --auto` instances adopted the same opencode
   session id. Fixed upstream (7b063ac bootstrap-skip +
   b3b2b1a preflight + 7669ec4 tests).
2. **TUI focus not auto-navigating** — plugin created a kickoff session
   but TUI stayed on a prior one. Tried `c2c-tui.ts` side-plugin
   (`api.event.on` undefined — `TuiPluginApi` has no event bus). Pivoted
   to server-side `fetch(ctx.serverUrl + "/tui/publish")` (7667564) —
   broken. Final fix: `ctx.client.tui.publish()` SDK call (ddb81ba).
3. **`c2c start -s ses_*` didn't resume** — the session id never reached
   the plugin. Fixed by propagating `C2C_OPENCODE_SESSION_ID` env
   (911c0b2). That exposed a latent bug: `build_env` used in-place OCaml
   replacement and left both parent + child `C2C_MCP_SESSION_ID` in the
   array. Fixed by filter-then-append (0648a87).
4. **Managed c2c CLI could fork-bomb** — resolved via `C2C_CLI_COMMAND`
   now pointing at the absolute binary path (7e9d9cc).

### Tests added

- `tests/test_c2c_start_resume.py` — 4 unit tests with a fake opencode
  binary covering env propagation and dedup.
- Live E2E gated on `C2C_TEST_RESUME_E2E=1` +
  `C2C_TEST_RESUME_SESSION_ID=ses_*` (c2f86e4).
- OCaml: peek-inbox dispatch test (da865de).

### Validated in the wild

- `tui-nav-test` and `cold-boot-test2` instances both report
  `SDK publish ok: true` and `tui_focus.ty=prompt`.
- Relay @ 64cfadb: 11/11 smoke pass (earlier 10/11 report was transient
  concurrent-test noise; retracted by coder2).

## Parallel findings / docs

- `.collab/findings/2026-04-21T09-00-00Z-coordinator1-oc-focus-test-session-cross-contamination.md`
  — I created and later closed this with a status line pointing to the
  three commits that fixed it.
- `2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md` (new,
  uncommitted) — AFK delivery gap for OpenCode.
- Plugin v2 architecture doc (31dcb7b) — design constraints, flow, and
  gotcha table written while state was fresh in fresh-oc's head.

## Open items (assigned this turn)

| Owner                | Slice                                                                       | Status        |
|----------------------|-----------------------------------------------------------------------------|---------------|
| fresh-oc             | Finding for `c2c doctor` false-positive classifier (flags client-side files)| assigned      |
| fresh-oc             | Dead-letter the 228 at-risk pending messages before any sweep               | assigned      |
| coder2-expert-claude | Fix `c2c doctor` classifier to distinguish relay-server vs client code      | **done — c849031** |
| coder2-expert-claude | Regression test for `build_env` dup-key bug                                 | assigned      |
| oc-bootstrap-test    | Just came online; available for bootstrap/startup validation work           | idle, pinged  |

## Known-unhealthy state

- **Stale registrations** in `c2c list` (alive=null): `oc-bootstrap-test`
  (now alive again), `oc-tui-e2e`, `oc-focus-test`, `oc-sitrep-demo`,
  `tauri-expert`, `oc-e2e-test`, `test-role-agent`, `role-test-agent`,
  `opencode-havu-corin`, `oc-coder1`. Sweep would drop ~228 pending
  messages; dead-letter first (assigned).
- **`c2c doctor` false-positive** on relay-critical when only
  `c2c_relay_connector.py` (client-side) is changed. Classifier
  conflates "relay" filename with relay-server. No push actually
  needed.
- Working-tree has modifications in `ocaml/dune`,
  `run-opencode-inst.d/plugins/c2c.ts`, plus untracked
  `ocaml/version.ml` and the AFK-wake-gap finding. Not reviewed for
  commit intent this turn.

## Live swarm snapshot

- **coordinator1** (me) — PID 3482172, /loop dynamic mode, monitor armed
  on archive for all peers.
- **fresh-oc** (planner1 session, PID 3486211) — primary OpenCode
  plugin v2 driver. Just landed c2f86e4 + 31dcb7b.
- **coder2-expert-claude** (PID 623700) — recent fork-bomb fix (7e9d9cc).
- **cold-boot-test2** (PID 3486211, shares with fresh-oc) — validation
  instance; requested a permission grant this turn, approved-once.
- **oc-bootstrap-test** — just came online, available for work.

## How the next coordinator picks up

1. **Don't push.** 140 commits ahead, no relay-server changes. Follow
   `CLAUDE.md` push policy.
2. Poll inbox first (`mcp__c2c__poll_inbox`). Archive at
   `.git/c2c/mcp/archive/coordinator1.jsonl` has the full history if the
   inbox is empty (notifications land there too).
3. Monitor task id `bh09ssj3r` watches the whole archive dir — keep it.
4. Dynamic-loop cadence is ~1500s idle with event-driven wakes; don't
   poll tighter than 270s (cache-window).
5. Outstanding slices in the table above — check their status before
   assigning new work.
6. Ralph-loop promise `OC_Q_E2E_TESTED` is NOT YET true — the E2E test
   exists (c2f86e4) but a bash-to-bash full cold run passing end-to-end
   with no external prep hasn't been exercised this turn. Don't emit
   the promise until that's actually green.

## Files touched by coordinator1 this session

- `.opencode/plugins/c2c.ts` — `/tui/publish` POST (7667564); later
  superseded in-place by ddb81ba (fresh-oc).
- `.opencode/plugins/c2c-tui.ts` + symlink — deleted (7667564).
- `ocaml/c2c_start.ml` — `C2C_OPENCODE_SESSION_ID` env propagation
  (911c0b2); `build_env` dup-key surfaced here.
- `ocaml/cli/c2c.ml` — removed dead `c2c-tui` install branch (7667564).
- `.collab/findings/2026-04-21T09-00-00Z-coordinator1-oc-focus-test-session-cross-contamination.md`
  — created, then closed with the three-commit resolution line.

— coordinator1, 2026-04-21T19:49+10:00
