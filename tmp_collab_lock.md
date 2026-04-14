# c2c Collaboration Lock (storm-beacon ↔ storm-echo)

Both sessions share `/home/xertrov/src/c2c-msg` as their working directory.
To avoid clobbering each other's edits, claim a lock on any file you're about to
modify. Release it immediately after you're done (committed or intentionally left
on disk).

## Active locks

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
| _none_ | | | |

## History (addendum)

- 2026-04-14T02:16Z - codex RELEASED locks on
  `.collab/findings/2026-04-14T02-15-00Z-codex-c2c-start-nonloop-test-failures.md`
  and `tmp_collab_lock.md`. Logged full-suite failures caused by unrelated
  uncommitted `c2c_start.py` / `CLAUDE.md` edits that change `c2c start` loop
  semantics without updating `tests/test_c2c_start.py`.

- 2026-04-14T02:14Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `tests/test_c2c_kimi_crush.py`, `tmp_status.txt`, and
  `tmp_collab_lock.md`. Split Kimi/Crush configure and managed launcher
  coverage into a dedicated test module, bringing `tests/test_c2c_cli.py` down
  to 5,603 lines. Verification: affected module collection 240 tests, focused
  affected modules 240/240, `py_compile`, `git diff --check`, and full
  `just test` with 968 Python tests plus OCaml build/runtest.

- 2026-04-14T01:55Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `tests/test_c2c_opencode.py`, `tmp_status.txt`, and
  `tmp_collab_lock.md`. Split OpenCode local config, plugin/install,
  configure-opencode, and restart-opencode coverage into a dedicated test
  module, bringing `tests/test_c2c_cli.py` down to 6,658 lines. Verification:
  affected module collection 272 tests, focused affected modules 272/272,
  `py_compile`, `git diff --check`, and full `just test` with 969 Python tests
  plus OCaml build/runtest.

- 2026-04-14T01:45Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `tests/test_c2c_maintenance.py`, `tmp_status.txt`, and
  `tmp_collab_lock.md`. Split wake/refresh, dead-letter, broker-GC, sweep, and
  room-prune maintenance coverage into a dedicated test module, bringing
  `tests/test_c2c_cli.py` down to 7,887 lines. Verification: affected module
  collection 329 tests, focused affected modules 329/329, `py_compile`,
  `git diff --check`, and full `just test` with 969 Python tests plus OCaml
  build/runtest.

- 2026-04-14T01:35Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `tests/test_c2c_start.py`, `tmp_status.txt`, and `tmp_collab_lock.md`.
  Split managed-instance `c2c start` coverage into a dedicated test module,
  bringing `tests/test_c2c_cli.py` down to 9,000 lines. Verification: affected
  module collection 373 tests, focused affected modules 373/373,
  `py_compile`, `git diff --check`, and full `just test` with 969 Python tests
  plus OCaml build/runtest.

- 2026-04-14T01:31Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `tests/test_c2c_health.py`, `tests/test_c2c_status.py`, `tmp_status.txt`,
  and `tmp_collab_lock.md`. Split the oversized CLI test module by moving
  health-specific coverage into `tests/test_c2c_health.py` and older status
  coverage into `tests/test_c2c_status.py` as `C2CStatusLegacyTests`.
  Verification: affected module collection 469 tests, focused affected modules
  469/469, `py_compile`, `git diff --check`, and full `just test` with 969
  Python tests plus OCaml build/runtest.

- 2026-04-14T01:28Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T01-24-00Z-codex-health-sweep-warning-no-safe-preview.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Health's active outer-loop
  warning now points operators to `c2c sweep-dryrun` as the safe read-only
  cleanup preview. Verification: RED print regression failed on missing hint,
  focused health print tests 9/9, `py_compile`, `git diff --check`, live
  `./c2c health`, and full `just test` with 969 Python tests plus OCaml
  build/runtest.

- 2026-04-14T01:17Z - codex RELEASED locks on `c2c_sweep_dryrun.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T01-14-00Z-codex-sweep-dryrun-duplicate-pid-blindspot.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Safe sweep preview now reports
  duplicate PID groups and likely zero-activity ghost aliases using broker
  archive activity. Live `./c2c sweep-dryrun --json` and text output identify
  `opencode-c2c-msg` as the likely stale duplicate-PID alias while remaining
  read-only. Verification: RED regressions failed on missing JSON/text section,
  focused tests 2/2, `py_compile`, `git diff --check`, live command checks,
  and full `just test` with 968 Python tests plus OCaml build/runtest.

- 2026-04-14T01:08Z - codex RELEASED locks on `c2c_cli.py`,
  `c2c_sweep_dryrun.py`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T01-05-00Z-codex-sweep-dryrun-dispatch-gap.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Wired documented
  `c2c sweep-dryrun` through the top-level dispatcher, updated
  `c2c_sweep_dryrun.main(argv)` to accept forwarded args, and fixed checkout
  fixture copying for the newly imported module. Live `./c2c sweep-dryrun
  --json` now returns the read-only cleanup preview. Verification: RED
  dispatcher test failed on missing module, RED argv test failed on TypeError,
  focused tests 3/3, `py_compile`, `git diff --check`, live command, and full
  `just test` with 966 Python tests plus OCaml build/runtest.

- 2026-04-14T00:57Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T00-54-00Z-codex-duplicate-pid-warning-ambiguity.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Duplicate-PID health entries now
  include `likely_stale_aliases` derived from archive activity, and human
  output names likely zero-activity ghost aliases directly. Live health now
  reports `opencode-c2c-msg` as the likely stale alias sharing Codex's PID.
  Verification: RED regressions failed on missing JSON key and missing text;
  focused registry/print tests 13/13, `py_compile`, `git diff --check`, live
  `./c2c health --json`, live `./c2c health`, and full `just test` with 964
  Python tests plus OCaml build/runtest.

- 2026-04-14T00:49Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T00-45-00Z-codex-health-pending-total-ambiguity.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Health stale-inbox reporting now
  exposes below-threshold queued message totals separately from thresholded
  stale/inactive inboxes and prints the remainder line in human output.
  Verification: RED regressions failed on missing JSON keys and missing text
  summary; focused health tests 17/17, `py_compile`, `git diff --check`, live
  `./c2c health --json`, live `./c2c health`, and full `just test` with 962
  Python tests plus OCaml build/runtest.

- 2026-04-14T00:39Z - codex RELEASED locks on `c2c_deliver_inbox.py`,
  `c2c_wake_peer.py`, `tests/test_c2c_cli.py`,
  `tests/test_c2c_deliver_inbox.py`,
  `.collab/findings/2026-04-14T00-33-00Z-codex-wake-peer-json-message-body-leak.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Notify-only JSON output now
  redacts broker message bodies at both `c2c_deliver_inbox.py --notify-only
  --json` and `c2c wake-peer --json`, preserving `message_count` and
  `messages_redacted` metadata while keeping raw messages internal for debounce
  signatures. Verification: RED regressions failed on leaked sentinel bodies;
  focused deliver/wake tests 14/14, `py_compile`, `git diff --check`, and full
  `just test` with 961 Python tests plus OCaml build/runtest.

- 2026-04-14T00:27Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T00-23-00Z-codex-duplicate-pid-stale-inbox-actionability.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Health stale-inbox reporting now
  treats duplicate-PID, zero-archive-activity aliases as inactive artifacts
  when a sibling alias with the same PID has real archive activity. Live health
  moved `opencode-c2c-msg` from actionable stale to inactive stale while
  leaving `claude-main` as the only actionable stale inbox. Verification:
  focused stale-inbox tests 11/11, `py_compile`, `git diff --check`, full
  `just test` with 959 Python tests plus OCaml build/runtest, live
  `./c2c health --json`, and live `./c2c status` showing `swarm-lounge` 5/5.

- 2026-04-14T00:17Z - codex RELEASED locks on `c2c_kimi_wire_bridge.py`,
  `tests/test_c2c_kimi_wire_bridge.py`,
  `.collab/findings/2026-04-14T00-13-00Z-codex-kimi-wire-child-pid-clobber.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Fixed Kimi Wire MCP configs to
  set `C2C_MCP_CLIENT_PID` to the durable bridge process PID so short-lived
  `kimi --wire` children do not clobber the `kimi-nova-2` registration. Live
  mitigation refreshed `kimi-nova-2` back to the running Wire daemon, then
  restarted the daemon to pid 748416 and verified `swarm-lounge` 5/5 alive.
  Verification: RED config regression failed on missing env key, focused Kimi
  Wire tests 42/42, Wire daemon lifecycle test 1/1, `py_compile`,
  `git diff --check`, and full `just test` with 958 Python tests plus OCaml
  build/runtest.

- 2026-04-14T00:08Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T09-55-00Z-kimi-nova-duplicate-pid-ghost-opencode-c2c-msg.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Kimi had already committed the
  duplicate-PID health slice as `fbc7dfc`; codex adopted the result, confirmed
  the focused registry/print tests, and synced shared status docs to the new
  958-test count and duplicate-PID health warning.

- 2026-04-14T09:59Z - kimi-nova-2 RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-14T09-55-00Z-kimi-nova-duplicate-pid-ghost-opencode-c2c-msg.md`,
  and `tmp_collab_lock.md`. Added duplicate-PID detection to `c2c health`
  (`check_registry()`) and 5 regression tests (`HealthCheckRegistryTests`).
  Live `./c2c health` now reports the `opencode-c2c-msg` / `codex` duplicate
  PID ghost (pid 552302). Also sent a DM to `claude-main` about its 21-message
  pending inbox and documented the `opencode-c2c-msg` ghost in findings.
  Verification: focused registry tests 5/5, full `tests/test_c2c_cli.py`
  446/446, `py_compile`, `git diff --check`.

- 2026-04-13T23:59Z - codex RELEASED locks on `c2c_health.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T23-55-00Z-codex-health-stale-inbox-noise.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Split health stale-inbox
  reporting into live actionable `stale` and retained inactive
  `inactive_stale` artifacts, preserving no-registry fallback behavior for
  isolated brokers. Verification: focused health tests 14/14, `py_compile`,
  `git diff --check`, full `just test` with 952 Python tests plus OCaml
  build/runtest, live `./c2c health --json`, and live `./c2c status --json`
  showing `swarm-lounge` 5/5 alive.

- 2026-04-13T23:53Z - codex RELEASED locks on `c2c_wire_daemon.py`,
  `run-kimi-inst-outer`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T23-45-00Z-codex-kimi-tui-fast-exit-wire-daemon-registration.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Diagnosed Kimi room liveness
  dropping to 4/5: the legacy TUI inner process was fast-exiting in a headless
  context and repeatedly refreshing the broker to dead child PIDs. Fixed
  `c2c wire-daemon start` to refresh broker registration to the live daemon PID
  and changed `run-kimi-inst-outer` to prefer an active Wire daemon PID over a
  short-lived TUI child. Live mitigation: started `kimi-nova` Wire daemon as
  `kimi-nova-2`, stopped stale `run-kimi-inst-outer kimi-nova`, refreshed the
  broker row to pid 709877, and verified `swarm-lounge` 5/5 alive. Verification:
  focused Kimi/Wire tests 14/14, `py_compile`, `git diff --check`, and full
  `just test` with 948 Python tests plus OCaml build/runtest.

- 2026-04-13T23:34Z - codex RELEASED locks on `c2c_status.py`,
  `tests/test_c2c_status.py`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T23-31-43Z-codex-status-zero-activity-ghost.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Verified the requested room join
  `c2c-system` broadcast behavior was already present in OCaml, Python CLI
  fallback, and relay paths, then fixed compact status to default-filter
  zero-activity live ghost registrations while preserving `--min-messages 0`
  for debugging. Verification: status RED tests failed for missing filter/flag;
  focused status tests 32/32, room/relay join-notice tests 83/83, live
  `./c2c status --json`, `py_compile`, `git diff --check`, OCaml runtest, and
  full `just test` with 946 Python tests plus OCaml build/runtest.

- 2026-04-13T23:29Z - codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`, `c2c_room.py`, `tests/test_c2c_room.py`,
  `.collab/findings/2026-04-13T23-24-00Z-codex-room-join-rebroadcast-noise.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Fixed duplicate room join
  rebroadcast noise for exact existing members that were not the last entry in
  `members.json`; exact duplicate joins now short-circuit, while real
  alias/session updates replace in place. Verification: RED OCaml regression
  failed on extra system message; GREEN OCaml `dune runtest` 118 tests and
  Python room tests 21/21; full `just test` passed with 943 Python tests plus
  OCaml build/runtest.

- 2026-04-13T23:16Z - codex RELEASED locks on `c2c_start.py`,
  `run-crush-inst-outer`, `tests/test_c2c_cli.py`, `tmp_status.txt`, and
  `tmp_collab_lock.md`. Adopted the committed deliver-client enum fix and
  repaired harness tests exposed by full-suite verification: isolated
  `run_outer_loop` tests from broker-root subprocess discovery, stale tmp
  cleanup, and sidecar process mocks; updated SIGINT/backoff expectations to
  match the current fatal-return behavior; and isolated the OpenCode no-TTY
  rearm test from the live broker root. Verification: focused harness tests
  43/43, `py_compile`, `git diff --check`, and full `just test` with
  942 Python tests plus OCaml build/runtest.

- 2026-04-13T23:06Z - codex RELEASED locks on `c2c_start.py`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T22-56-00Z-codex-c2c-start-kimi-live-proof.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Verified the Kimi managed-start
  identity fix: RED tests failed on missing `prepare_launch_args`; GREEN
  `C2CStartUnitTests` passed 19/19; live `c2c start kimi -n
  kimi-start-proof-codex2` reported whoami `kimi-start-proof-codex2` and sent
  marker `C2C_START_KIMI_INSTANCE_ID_PROOF_1776121240` from that alias/session.
  The proof instance was stopped, generated instance state removed, and
  `prune_rooms` evicted the dead proof member. Verification: focused start
  tests 19/19, `py_compile`, `git diff --check`, and full `just test` with
  934 Python tests plus OCaml build/runtest.

- 2026-04-13T22:49Z - codex RELEASED locks on `c2c_refresh_peer.py`,
  `c2c_registry.py`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T22-44-00Z-codex-refresh-peer-alias-session-id-drift.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Fixed `refresh-peer` to resolve
  by alias first and `--session-id` second, covering managed-client alias
  drift such as session `kimi-nova` currently registered as alias
  `kimi-nova-2`. Adopted the concurrent Python registry fallback so
  `load_registry()` reads broker `registry.json` when legacy YAML is absent.
  Verification: RED drift regression failed with missing alias; GREEN
  `RefreshPeerTests` passed 11/11; full `just test` passed with 928 Python
  tests plus 117 OCaml tests.

- 2026-04-13T22:49Z - codex RELEASED lock on `docs/index.md`. Adopted the
  concurrent homepage refresh after full test pass; no code behavior affected.

- 2026-04-13T22:53Z - codex RELEASED locks on `c2c_start.py`,
  `tests/test_c2c_cli.py`, `tmp_status.txt`, and `tmp_collab_lock.md`.
  Adopted the concurrent `c2c start --bin` override slice, including persisted
  `binary_override` config and restart reuse. Verification:
  `C2CStartConstantsTests` passed 17/17.

- 2026-04-13T22:33Z - codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`,
  `.collab/findings/2026-04-13T22-26-00Z-codex-prune-rooms-orphan-member-gap.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Fixed `prune_rooms` so it
  evicts room members whose registry rows are already gone, matching
  `list_rooms` dead-member reporting for orphan memberships. Verification:
  RED orphan-member regression failed with 0 evictions, GREEN OCaml
  `dune runtest` passed 117/117. Full `just test` is blocked by unrelated
  dirty configure/start work (`c2c_configure_claude_code.py` indentation error
  and alias expectation drift).

- 2026-04-13T22:36Z - codex RELEASED locks on `tmp_status.txt` and
  `tmp_collab_lock.md`. After self-restart, live MCP `prune_rooms` evicted
  orphan `storm-beacon` from `swarm-lounge`; follow-up `list_rooms` reported
  4/4 alive room members.

- 2026-04-13T22:16Z - codex RELEASED locks on `.opencode/opencode.json`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T22-13-00Z-codex-opencode-config-inherits-parent-alias.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Pinned the repo-local OpenCode
  MCP config to `C2C_MCP_AUTO_REGISTER_ALIAS=opencode-c2c-msg`, closing the
  alias-drift path where OpenCode launched from Kimi inherited `kimi-nova` as
  its auto-register alias and registered `opencode-c2c-msg` under Kimi's live
  PID. Verification: red/green repo-config regression, configure-opencode
  focused tests, `py_compile`, and full `just test` with 901 Python tests plus
  116 OCaml tests.

- 2026-04-13T22:06Z - codex RELEASED locks on `c2c_relay_contract.py`,
  `c2c_relay_sqlite.py`, `tests/test_relay_rooms.py`,
  `tests/test_relay_sqlite.py`, `tests/test_relay_rooms_cli.py`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Added relay parity for room join
  system notices: InMemoryRelay and SQLiteRelay now append `c2c-system` join
  notices to room history and fan them out to all current members, including
  the joiner. Verification: focused red/green join notice tests, relay room
  suites, `py_compile`, and full `just test` with 888 Python tests plus 116
  OCaml tests. Briefly claimed `ocaml/c2c_mcp.ml` for an upstream build break,
  but the live worktree already had the missed caller repaired before edit; no
  OCaml changes were committed by codex in this slice.

- 2026-04-13T21:52Z - codex RELEASED locks on `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T21-50-00Z-codex-dune-lock-and-env-leak.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Fixed the copied-checkout
  register/list test to use an explicit temp `C2C_MCP_BROKER_ROOT` and blank
  managed auto-register env vars, documented the Dune empty lock and env leak
  failures, and synced the Python test count to 882. Verification: focused
  copied-checkout test and full `just test` with OCaml build/runtest plus 882
  Python tests.

- 2026-04-13T21:28Z - codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/c2c_mcp.mli`, `ocaml/test/test_c2c_mcp.ml`, `c2c_room.py`,
  `tests/test_c2c_room.py`, `tests/test_c2c_onboarding_smoke.py`,
  `.collab/findings/2026-04-13T21-26-24Z-codex-inflight-ocaml-edit-lost.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Implemented
  `c2c-system` room join broadcasts to all room members, including the joining
  agent, mirrored the behavior in Python CLI fallback, and adjusted history
  tests for non-silent joins. Verification: focused OCaml room suite, focused
  Python room/smoke tests, full `just test` with 868 Python tests plus OCaml
  build/runtest, and `git diff --check`.

- 2026-04-13T20:35Z - codex RELEASED locks on `c2c_cli.py`,
  `c2c_status.py`, `tests/test_c2c_status.py`, `tests/test_c2c_cli.py`,
  `docs/commands.md`, `docs/index.md`, `.goal-loops/active-goal.md`,
  `docs/next-steps.md`, `tmp_status.txt`, and `tmp_collab_lock.md`. The
  `c2c status` command was committed in `1bf69c2` and `f59f62f`; codex synced
  shared status docs to the verified count. Verification: `just test` passed
  with OCaml build/runtest plus 832 Python tests.

- 2026-04-13T19:52Z - codex RELEASED locks on
  `ocaml/test/test_c2c_mcp.ml`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. Adopted peer join_room/leave_room missing-alias
  regressions and synced the shared OCaml count to 110 / aggregate count to
  914. Verification: OCaml `dune runtest` passed, `just test` passed with 804
  Python tests plus OCaml build/runtest, and `git diff --check`.

- 2026-04-13T19:46Z - codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`,
  `.collab/findings/2026-04-13T19-25-00Z-codex-cli-help-and-send-room-footguns.md`,
  and `tmp_collab_lock.md`. Finished the option-returning sender alias
  resolution change for `send`, `send_all`, `join_room`, `leave_room`, and
  `send_room`; missing sender identity now returns a structured
  "missing sender alias" tool error instead of raw Yojson internals.
  Verification: OCaml `dune runtest` 108/108, `just test` with 804 Python
  tests plus OCaml build/runtest, and `git diff --check`.

- 2026-04-13T19:40Z - codex RELEASED locks on `c2c_cli.py`,
  `tests/test_c2c_cli.py`, `tests/test_c2c_smoke_test.py`,
  `c2c_smoke_test.py`, `docs/commands.md`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`,
  `.collab/findings/2026-04-13T19-25-00Z-codex-cli-help-and-send-room-footguns.md`,
  and `tmp_collab_lock.md`. Setup audit fixed top-level `c2c --help`, folded
  in the smoke-test coverage, repaired copied-checkout fixture imports, and
  documented the raw MCP `send_room` missing-alias error. Verification:
  focused CLI/smoke tests 14/14, full Python 804/804, `just test` 804 pytest
  + OCaml build/runtest, live `./c2c smoke-test --json`, and `git diff --check`.

- 2026-04-14T07:10Z — storm-beacon RELEASED codex freshness test locks on
  `tests/test_c2c_cli.py`, `tests/test_c2c_mcp_server_freshness.py`,
  `tmp_status.txt`, `.goal-loops/active-goal.md`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. Committed `server_is_fresh` freshness check tests (7
  new tests in `test_c2c_mcp_server_freshness.py`) and updated
  `test_c2c_cli.py` to mock `server_is_fresh` in the 6 build-path tests.
  Full suite: 791 Python tests pass.

- 2026-04-13T19:09Z — codex committed peer Crush-demotion follow-up docs in
  `.collab/dm-matrix.md`, `CLAUDE.md`, and `docs/next-steps.md`, plus this
  lock note. The slice removes Crush from the first-class DM matrix, marks
  Crush setup/wake helpers experimental, and keeps historical one-shot/active
  proof notes as context. Verification: stale-reference `rg` and
  `git diff --check`.

- 2026-04-13T19:08Z — codex RELEASED locks on
  `docs/_layouts/home.html`, `docs/architecture.md`,
  `docs/client-delivery.md`, `docs/communication-tiers.md`,
  `docs/cross-machine-broker.md`, `docs/index.md`, `docs/overview.md`, and
  `tmp_collab_lock.md`. Committed the peer docs slice that demotes Crush from
  first-class support to experimental/unsupported because it lacks context
  compaction and interactive TUI wake is unreliable. Tightened two stale
  references that still called Crush first-class/supported. Verification:
  docs stale-reference `rg` and `git diff --check`.

- 2026-04-13T19:06Z — codex RELEASED locks on
  `tests/test_c2c_dead_letter.py`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. Repaired peer dead-letter replay tests that were
  committed with a syntax error and stale mock boundary; tests now patch
  `c2c_send.send_to_alias` and assert the current dry-run behavior. Synced
  Python count to 784 and aggregate count to 890. Verification:
  `py_compile`, focused `tests/test_c2c_dead_letter.py` 14/14, full pytest
  784/784, `just test` 784 pytest + OCaml build/runtest, and `git diff --check`.

- 2026-04-13T19:00Z — codex RELEASED locks on `c2c_dead_letter.py`,
  `tests/test_c2c_cli.py`, `docs/commands.md`, `docs/next-steps.md`,
  `docs/architecture.md`, `CLAUDE.md`/`AGENTS.md`,
  `.goal-loops/active-goal.md`, `tmp_status.txt`,
  `.collab/findings/2026-04-13T18-52-33Z-codex-dead-letter-replay-root-drift.md`,
  and `tmp_collab_lock.md`. Fixed `c2c dead-letter --root X --replay`
  broker-root drift by binding `C2C_MCP_BROKER_ROOT` during replay, replaced
  the manual `c2c_send` module reload with a normal import, added two replay
  regressions, and documented the operator replay path. Verification:
  `py_compile`, focused replay tests 2/2, previously failing registry-read test
  1/1, full Python unittest discovery 770/770, `just test` 770 pytest + OCaml
  build/runtest, and `git diff --check`.

- 2026-04-13T18:45Z — codex RELEASED locks on `docs/overview.md`,
  `docs/communication-tiers.md`, `docs/client-delivery.md`, `tmp_status.txt`,
  and `tmp_collab_lock.md`. Updated stale Crush docs from written/untested to
  live-proven for Codex<->Crush notify-only PTY wake, kept other Crush live
  pairs marked as requiring per-pair proof, and named `ember-flame` as current
  live Crush alias.

- 2026-04-13T18:39Z — codex RELEASED locks on `tmp_status.txt` and
  `tmp_collab_lock.md`. Synced the `just test` aggregate count from stale 870
  to current Python 768 + OCaml 106 = 874.

- 2026-04-13T18:33Z — codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`, `c2c_room.py`, `tests/test_c2c_room.py`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, `tmp_status.txt`,
  `.collab/findings/2026-04-13T18-23-00Z-codex-room-rename-membership-drift.md`,
  and `tmp_collab_lock.md`. Extended the room rename fix so MCP startup
  auto-join prefers the current registered alias, OCaml and Python room joins
  deduplicate by alias or session ID, live `swarm-lounge` duplicate membership
  was collapsed to `ember-flame`, and shared test counts are now Python 768 /
  OCaml 106.

- 2026-04-13T18:27Z — codex RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`,
  `.collab/findings/2026-04-13T18-23-00Z-codex-room-rename-membership-drift.md`,
  `tmp_status.txt`, `docs/next-steps.md`, and `tmp_collab_lock.md`. Fixed
  same-session register renames so room membership aliases follow the registry,
  added a regression, documented the live drift, and repaired `swarm-lounge`
  membership from `crush-xertrov-x-game` to `ember-flame`.

- 2026-04-13T18:21Z — codex RELEASED locks on
  `.collab/findings/2026-04-13T18-20-56Z-codex-ignored-goal-loops-add-footgun.md`
  and `tmp_collab_lock.md`. Documented the ignored `.goal-loops` add footgun
  encountered while committing the status sync.

- 2026-04-13T18:19Z — codex RELEASED locks on `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. Synced active-goal and next-steps with the latest
  `3824610` register fresh-entry fix, all-client `c2c history` session env
  resolution, and Python 766 / OCaml 104 test counts from the current shared
  status.

- 2026-04-13T18:08Z — codex RELEASED locks on `c2c_room.py`,
  `tests/test_c2c_room.py`, `ocaml/c2c_mcp.ml`, `ocaml/c2c_mcp.mli`,
  `ocaml/test/test_c2c_mcp.ml`, `docs/commands.md`, and
  `tmp_collab_lock.md`. Room-list liveness summaries landed in `359cebf`
  alongside the history CLI slice: `alive_member_count`,
  `dead_member_count`, `unknown_member_count`, and `member_details` now make
  stale room memberships visible. Verification: `tests.test_c2c_room` 16/16,
  `py_compile c2c_room.py tests/test_c2c_room.py`, OCaml `dune runtest`
  104/104, full Python unittest discovery 762/762, and live
  `./c2c room list --json` shows the new fields.

- 2026-04-13T17:52Z — codex RELEASED locks on `run-crush-inst`,
  `tests/test_c2c_cli.py`, `ocaml/c2c_mcp.ml`,
  `ocaml/test/test_c2c_mcp.ml`, `tmp_status.txt`, and
  `.goal-loops/active-goal.md`. Adopted the committed Crush
  `crush_session_id` launch support with regression tests, completed MCP
  tool `inputSchema.properties`, refreshed stale goal test counts, and
  preserved the alias-hijack register guard docs. Verification: focused
  `RunCrushInstTests` 11/11, `py_compile` for the launcher tests, full
  Python unittest discovery 752/752, and OCaml `dune runtest` 101/101.

- 2026-04-13T17:48Z — codex RELEASED locks on `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`,
  `docs/client-delivery.md`, `.collab/dm-matrix.md`, `AGENTS.md`/`CLAUDE.md`,
  and `.collab/findings/2026-04-13T17-35-58Z-codex-crush-interactive-tui-wake-proof.md`.
  Documented the live Codex<->Crush interactive TUI wake proof:
  broker-native direct DM, notify-only PTY nudge, Crush MCP poll, and direct MCP
  reply with `CRUSH_INTERACTIVE_WAKE_ACK 1776101709`.

- 2026-04-13T17:31Z — codex-xertrov-x-game RELEASED locks on
  `run-crush-inst-outer`, `tests/test_c2c_cli.py`, and
  `.collab/findings/2026-04-13T17-29-00Z-codex-crush-outer-refresh-peer-gap.md`.
  Added Crush outer-loop refresh-peer on child spawn plus regression tests.

- 2026-04-13T17:46Z — codex-xertrov-x-game RELEASED locks on
  `tmp_status.txt` and `.goal-loops/active-goal.md`. Updated global test counts
  to Python 744 and OCaml 98 after the latest regression tests landed.

- 2026-04-13T17:42Z — codex-xertrov-x-game RELEASED locks on
  `ocaml/c2c_mcp.ml`, `ocaml/test/test_c2c_mcp.ml`, and
  `.collab/findings/2026-04-13T17-14-28Z-codex-generic-alias-reply-misroute.md`.
  OCaml MCP sender alias binding is committed and verified; finding status
  updated.

- 2026-04-13T17:25Z — codex RELEASED locks on `run-kimi-inst-outer` and
  `tests/test_c2c_cli.py`. Added focused Kimi outer refresh-peer session-id
  coverage.

- 2026-04-13T17:20Z — codex RELEASED locks on `c2c_refresh_peer.py` and
  `tests/test_c2c_cli.py`. Normalized new refresh-peer output/comment arrows
  to ASCII before follow-up verification.

- 2026-04-13T17:18Z — codex RELEASED lock on `docs/client-delivery.md`.
  Fixed trailing whitespace in the live active-session DM matrix legend before
  verification.

- 2026-04-13T16:58Z — codex RELEASED stale locks on
  `c2c_kimi_wire_bridge.py`, `c2c_configure_kimi.py`,
  `tests/test_c2c_kimi_wire_bridge.py`, `docs/commands.md`,
  `docs/client-delivery.md`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, `AGENTS.md`,
  `CLAUDE.md`, and `tmp_collab_lock.md`. Follow-up commits had already landed
  the daemon implementation/status/docs; this release clears false active
  ownership for the swarm.

- 2026-04-13T17:06Z — codex RELEASED locks on
  `.goal-loops/active-goal.md` and `tmp_collab_lock.md`. Synced active-goal
  Python test count to 707 to match the latest shared status update.

- 2026-04-13T17:03Z — codex RELEASED locks on `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. Marked Kimi's true two-machine Tailscale relay proof
  complete across shared status docs: x-game ↔ xsm, broker-native DMs in both
  directions, room join, and room fan-out over the real network.

- 2026-04-13T16:58Z — codex RELEASED locks on `run-claude-inst-outer`,
  `tests/test_c2c_cli.py`, `docs/next-steps.md`,
  `.collab/findings/2026-04-13T16-36-36Z-codex-claude-outer-refresh-peer-gap.md`,
  and `tmp_collab_lock.md`. Added immediate `c2c_refresh_peer.py` refresh to
  Claude's outer loop after child spawn, matching Codex/OpenCode/Kimi behavior.
  Regression tests cover the post-spawn refresh and config alias lookup.
  Verification: focused Claude outer tests 2/2 and `py_compile` passed.

- 2026-04-13T16:47Z — codex RELEASED locks on `docs/client-delivery.md`,
  `docs/communication-tiers.md`, `tmp_status.txt`,
  `.goal-loops/active-goal.md`, `AGENTS.md`, `CLAUDE.md`,
  `docs/next-steps.md`, `c2c_kimi_wire_bridge.py`, and
  `tmp_collab_lock.md`. Documented Kimi Wire persistent `--loop` mode in
  client/agent docs and refreshed Kimi Wire status to 31 tests. Verified the
  peer broker-root default fix with `python3 -m unittest
  tests.test_c2c_kimi_wire_bridge -v` (31/31) and `c2c-kimi-wire-bridge
  --help`.

- 2026-04-13T16:34Z — codex RELEASED locks on `c2c_kimi_wire_bridge.py`
  and `tmp_collab_lock.md`. Committed the Kimi Wire bridge module docstring
  clarification: Wire avoids PTY/PTS hacks, master-side PTY wake remains the
  manual TUI fallback, and `/dev/pts/<N>` slave writes are display-only.

- 2026-04-13T16:28Z — codex RELEASED locks on `tmp_status.txt`,
  `.goal-loops/active-goal.md`,
  `.collab/findings/2026-04-14T01-58-00Z-kimi-nova-kimi-idle-pts-inject-live-proof.md`,
  `.collab/findings/2026-04-13T15-30-00Z-kimi-nova-kimi-idle-pts-inject-fix.md`,
  `docs/superpowers/specs/2026-04-14-kimi-wire-bridge-design.md`,
  `docs/superpowers/plans/2026-04-14-kimi-wire-bridge.md`,
  `.collab/findings/2026-04-13T16-22-17Z-codex-kimi-direct-pts-status-drift.md`,
  and `tmp_collab_lock.md`. Corrected stale Kimi direct-PTS status drift:
  master-side `pty_inject` is the proven manual TUI fallback, direct
  `/dev/pts/<N>` slave writes are display-side diagnostics only, and Kimi Wire
  remains the preferred native path.

- 2026-04-13T16:19Z — codex RELEASED locks on `c2c_inject.py`,
  `c2c_deliver_inbox.py`, `c2c_kimi_wake_daemon.py`, `c2c_pts_inject.py`,
  `tests/test_c2c_cli.py`, `tests/test_c2c_kimi_wake_daemon.py`,
  `AGENTS.md`, `CLAUDE.md`, `docs/client-delivery.md`,
  `docs/known-issues.md`, `docs/next-steps.md`,
  `.collab/findings/2026-04-13T16-12-18Z-codex-kimi-pts-slave-write-not-input.md`,
  `.collab/findings/2026-04-14T01-58-00Z-kimi-nova-kimi-idle-pts-inject-live-proof.md`,
  and `tmp_collab_lock.md`. Kimi wake/inject now uses master-side `pty_inject`
  with default submit delay 1.5s; direct `/dev/pts` slave writes are documented
  as display-side only. Live notify-only nudge drained `kimi-nova` from 2
  queued messages to 0. Verification: focused Kimi inject/deliver tests 2/2,
  Kimi wake + pts tests 12/12, `py_compile`, and `git diff --check` passed.

- 2026-04-13T16:12Z — codex RELEASED locks on
  `.collab/findings/2026-04-13T16-10-03Z-codex-kimi-wire-live-once-proof.md`,
  `tmp_status.txt`, and `tmp_collab_lock.md`. Live-proved
  `c2c-kimi-wire-bridge --once` against a real `kimi --wire` subprocess using
  an isolated temp broker: delivered 1 broker message, received a Kimi
  acknowledgment, cleared spool, and exited rc=0. Verification:
  `git diff --check` passed for the docs/status changes.

- 2026-04-13T16:04Z — codex RELEASED locks on
  `docs/superpowers/plans/2026-04-14-kimi-wire-bridge.md`,
  `tests/test_c2c_kimi_wire_bridge.py`, `c2c_kimi_wire_bridge.py`,
  `c2c-kimi-wire-bridge`, `c2c_install.py`, `tests/test_c2c_cli.py`,
  `docs/client-delivery.md`, `docs/overview.md`, and `tmp_collab_lock.md`.
  Kimi Wire bridge plan/tests/docs/install work landed in `99d8180`; follow-up
  fixture fix adds `c2c_kimi_wire_bridge.py` to the synthetic checkout used by
  `copy_cli_checkout`. Verification: focused Kimi Wire tests 20/20, focused
  install/kimi/copy tests 24/24, targeted copy/install tests 2/2, full Python
  suite 691/691, `py_compile`, and `git diff --check` passed.

- 2026-04-13 15:41Z — codex RELEASED locks on `c2c_mcp.py`,
  `run-kimi-inst`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T15-41-00Z-codex-kimi-mcp-stale-client-pid.md`,
  and `tmp_collab_lock.md`. Fixed Kimi MCP auto-register stale client PID
  fallback: dead `C2C_MCP_CLIENT_PID` values now fall back to the live parent
  process, and Kimi managed launches now set `KIMI_CLI_C2C_STEER_STREAMING=1`
  for c2c PTY-wake prompts. Verification: focused `tests/test_c2c_cli.py`
  selections for MCP auto-register/Kimi paths passed.

- 2026-04-13 15:30Z — codex RELEASED locks on `tmp_status.txt`,
  `.collab/findings/2026-04-13T15-19-25Z-codex-kimi-rearm-stale-pidfile.md`,
  and `tmp_collab_lock.md`. `kimi-nova` is live again via a pts/0
  `run-kimi-inst-outer`: Kimi pid `3591998`, notify daemon pid `3592012`,
  broker alias refreshed to pid `3591998`. Stopped the duplicate detached
  `script(1)` relaunch attempt created during recovery.

- 2026-04-13 15:29Z — codex RELEASED locks on `tmp_status.txt`,
  `.collab/findings/2026-04-13T15-19-25Z-codex-kimi-rearm-stale-pidfile.md`,
  and `tmp_collab_lock.md`. Corrected the live verification note after broker
  pid `2959892` exited: the stale-pidfile fallback selected the right live pid,
  but `kimi-nova` itself is now offline and needs a separate relaunch/durability
  follow-up.

- 2026-04-13 15:27Z — codex RELEASED locks on `run-kimi-inst-rearm`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T15-19-25Z-codex-kimi-rearm-stale-pidfile.md`,
  and `tmp_collab_lock.md`. Fixed Kimi rearm stale-pidfile handling: rearm now
  validates the pidfile target, falls back to a live broker registration for
  the same session or alias, and refuses to start if no live target exists.
  Live `kimi-nova` rearm selected broker pid `2959892` over dead pidfile pid
  `2981321` and started notify daemon pid `3580740` against the live process.
  Verification: focused `RunKimiInstTests` 10/10, `py_compile`, and
  `git diff --check` passed.

- 2026-04-13 15:10Z — codex RELEASED locks on `tmp_status.txt`,
  `docs/known-issues.md`, and `tmp_collab_lock.md`. Refreshed shared status
  after the OpenCode native plugin proof: `opencode-local` pid `3523962`,
  promptAsync end-to-end proven with `PLUGIN_ENVELOPE_FIX_SMOKE_ACK`, Python
  tests at 652, and known issues now describe the wake daemon as fallback rather
  than saying plugin delivery is unproven.

- 2026-04-13 15:06Z — codex RELEASED locks on `.collab/dm-matrix.md`,
  `.collab/findings/2026-04-13T15-05-18Z-codex-opencode-plugin-promptasync-proof.md`,
  and `tmp_collab_lock.md`. Restarted managed `opencode-local` to load the
  plugin JSON-envelope parser fix, rearmed support loops against new pid
  `3523962`, sent a broker-native DM containing `PLUGIN_ENVELOPE_FIX_SMOKE`,
  and received `PLUGIN_ENVELOPE_FIX_SMOKE_ACK` from `opencode-local`. This
  proves OpenCode native plugin delivery via CLI poll plus
  `client.session.promptAsync`.

- 2026-04-13 14:58Z — codex RELEASED follow-up locks on
  `tests/test_c2c_cli.py` and `tmp_collab_lock.md`. After the dry-run fix,
  focused OpenCode tests still rewrote the ignored live sidecar because two
  non-dry fake-launch fixtures used the real repo as `cwd`. Moved those
  fixtures to temp project directories, rearmed live `opencode-local`, reran the
  focused OpenCode launcher suite, and confirmed `.opencode/c2c-plugin.json`
  stayed on `opencode-local` afterward.

- 2026-04-13 14:55Z — codex RELEASED locks on `run-opencode-inst`,
  `run-opencode-inst-rearm`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T14-50-00Z-codex-opencode-dry-run-sidecar-drift.md`,
  and `tmp_collab_lock.md`. Fixed `run-opencode-inst` dry-run so it no longer
  mutates plugin-copy or sidecar state, added rearm-time sidecar refresh for
  OpenCode, documented the stale sidecar incident, and rearmed live
  `c2c-opencode-local` to restore `.opencode/c2c-plugin.json` to
  `opencode-local` / `ses_283b6f0daffe4Z0L0avo1Jo6ox`. Focused OpenCode
  launcher tests, `py_compile`, `git diff --check`, and managed plugin Bun
  build passed. Sent `opencode-local` a direct broker-native DM with the
  restart/delivery suggestions; its inbox drained.

- 2026-04-13 14:45Z — codex RELEASED locks on `.opencode/plugins/c2c.ts`,
  `run-opencode-inst`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T14-23-08Z-codex-opencode-plugin-quiet-runner.md`,
  `.collab/findings/2026-04-13T14-42-38Z-codex-opencode-rearm-poker-timeout.md`,
  and `tmp_collab_lock.md`. Added `opencode_session_id` to the managed
  OpenCode plugin sidecar and made the plugin prefer it for promptAsync target
  selection. Focused OpenCode launcher tests passed; plugin bundled under Bun.
  Live no-PTY test continued to prove broker drain but still did not produce a
  direct model reply, so promptAsync wake/visibility remains the next gap.

- 2026-04-13 14:36Z — codex RELEASED locks on `.opencode/plugins/c2c.ts`,
  `tests/test_c2c_cli.py`, `run-opencode-inst`, `.gitignore`,
  `.collab/findings/2026-04-13T14-23-08Z-codex-opencode-plugin-quiet-runner.md`,
  and `tmp_collab_lock.md`. Peer commits landed the OpenCode plugin drain
  fixes: replace unsupported `ctx.$.quiet` with `child_process.spawn`, write
  managed cwd `.opencode/c2c-plugin.json`, and start the plugin background
  poll loop during initialization. Live no-PTY test after restart drained the
  `PLUGIN_INIT_LOOP_LIVE_TEST` DM from `opencode-local.inbox.json` immediately;
  no reply had arrived yet, so promptAsync/model scheduling remains a separate
  verification gap. Support loops were restored afterward.

- 2026-04-14 00:16 — codex RELEASED locks on `docs/index.md`,
  `docs/known-issues.md`, and `tmp_collab_lock.md`. Updated public docs to mark
  the OpenCode TypeScript plugin as experimental/not live-proven after the
  managed-session live test failed to drain the broker without the PTY fallback.
  Also kept the cross-machine known issue aligned with the implemented relay.

- 2026-04-14 00:12 — codex RELEASED locks on
  `.collab/findings/2026-04-13T14-11-40Z-codex-opencode-plugin-live-test-no-drain.md`
  and `tmp_collab_lock.md`. Live-tested the OpenCode native plugin with the
  PTY notify daemon stopped; direct DM remained queued in the broker after
  20 seconds, so plugin delivery is not yet proven. Restored support loops with
  `run-opencode-inst-rearm`.

- 2026-04-14 00:07 — codex RELEASED locks on `.opencode/plugins/c2c.ts`,
  `c2c_configure_opencode.py`, `c2c_relay_server.py`, `c2c_cli.py`,
  `tests/test_c2c_cli.py`, `tests/test_configure_opencode.py`,
  `tests/test_relay_sqlite.py`, and `tmp_collab_lock.md`. Verified the
  OpenCode plugin sidecar config and SQLite relay server wiring that landed in
  `2fda077`. Focused SQLite, configure-opencode, relay server/GC tests,
  `py_compile`, and `git diff --check` passed.

- 2026-04-13 14:12 — codex RELEASED locks on `c2c_relay_sqlite.py`,
  `tests/test_relay_sqlite.py`, and `tmp_collab_lock.md`. Verified the
  untracked SQLite relay persistence slice after a transient GC accounting
  failure was fixed in the shared worktree. Focused
  `python3 -m unittest tests.test_relay_sqlite -v`, `py_compile`, and
  `git diff --check` passed.

- 2026-04-13 14:02 — codex RELEASED locks on `docs/index.md`,
  `docs/overview.md`, `docs/known-issues.md`, `docs/next-steps.md`,
  `llms.txt`, and `tmp_collab_lock.md`. Updated public docs and agent quick
  reference after `kimi-nova` proved manual TUI wake delivery via terminal wake
  daemon + broker-native `poll_inbox`. Crush remains blocked by missing
  provider credentials.

- 2026-04-13 13:57 — codex RELEASED locks on `c2c_cli.py`,
  `c2c_relay_config.py`, `c2c_relay_connector.py`, `c2c_relay_contract.py`,
  `c2c_relay_server.py`, `c2c_relay_gc.py`, `c2c_relay_rooms.py`,
  `tests/test_relay_config_status.py`, `tests/test_relay_gc.py`,
  `tests/test_relay_rooms_cli.py`, and `tmp_collab_lock.md`. Storm-ember
  committed the main relay GC/rooms CLI slice in `83494fb`/`623bfc5`; Codex
  kept only follow-up fixes: implement the documented `C2C_RELAY_URL`,
  `C2C_RELAY_TOKEN`, and `C2C_RELAY_NODE_ID` fallback, and make test/server
  helper constructors opt in to background GC threads so tests do not leak one
  sleeping daemon per ephemeral server.

- 2026-04-13 13:48 — codex RELEASED locks on `docs/index.md`,
  `docs/next-steps.md`, and `tmp_collab_lock.md`. Committed the relay
  quickstart website follow-up: homepage now links both cross-machine design
  and operator quickstart; next-steps marks relay docs complete and tracks
  remaining remote relay hardening. Verification: `git diff --check` on touched
  files passed.

- 2026-04-13 13:45 — codex RELEASED locks on
  `.collab/research/2026-04-13T13-35-21Z-codex-opencode-plugin-delivery.md`,
  `.collab/findings/2026-04-13T13-35-21Z-codex-opencode-plugin-delivery-research.md`,
  and `tmp_collab_lock.md`. Researched OpenCode plugin delivery using official
  OpenCode plugin/SDK docs plus the local `~/src/todoer` plugin example.
  Recommendation: replace OpenCode PTY message injection with a plugin that
  spools broker-drained messages and calls `client.session.prompt(...)`; keep
  PTY as fallback only.

- 2026-04-13 13:39 — codex RELEASED stale Phase 5 review locks on
  `c2c_cli.py`, `c2c_relay_config.py`, `c2c_relay_status.py`,
  `tests/test_relay_config_status.py`, `docs/next-steps.md`, and
  `tmp_collab_lock.md`. While Codex was reading the slice, commit `241195f`
  landed the Phase 5 setup/status/list work with 21 tests, so no code changes
  were needed from this review lock.

- 2026-04-13 13:35 — codex RELEASED locks on `c2c_relay_connector.py`,
  `tests/test_relay_connector.py`, `tests/test_c2c_relay_connector.py`, and
  `tmp_collab_lock.md`. Closed `HTTPError` response objects in the relay client
  after reading error payloads, joined the connector test server thread, and
  cleaned `TemporaryDirectory` fixtures through their cleanup API. Verification:
  `PYTHONWARNINGS=error::ResourceWarning python3 -m unittest
  tests.test_relay_connector -v` passed 16 tests; the richer
  `tests.test_c2c_relay_connector` suite passed 27 tests under the same warning
  setting; `py_compile` and `git diff --check` passed for touched files.

- 2026-04-13 13:26 — codex RELEASED locks on `tests/test_relay_rooms.py`
  and `tmp_collab_lock.md`. Committed the missing Phase 4 room/broadcast relay
  tests after the code landed in `34600a2`/`e83e474`. Verification:
  `python3 -m unittest tests.test_relay_rooms -v` passed 28 tests.

- 2026-04-13 13:24 — codex RELEASED locks on `c2c_relay_server.py`,
  `tests/test_relay_server.py`, `tests/test_c2c_relay_server.py`, and
  `tmp_collab_lock.md`. Fixed relay server/test ResourceWarnings by closing the
  listening socket on `shutdown()` and closing HTTPError response bodies after
  reading them. Verification: `PYTHONWARNINGS=error::ResourceWarning python3 -m
  unittest tests.test_relay_server -v` passed 24 tests; the richer untracked
  `tests.test_c2c_relay_server` suite passed 36 tests after the same helper
  cleanup. Separate connector-test warnings remain and were not covered by this
  lock.

- 2026-04-13 13:19 — codex RELEASED locks on
  `.collab/findings/2026-04-13T13-19-22Z-codex-relay-contract-untracked-tests.md`
  and `tmp_collab_lock.md`. Documented that Phase 1 relay contract work left a
  richer 68-test suite in untracked `tests/test_c2c_relay_contract.py` while the
  committed file has 33 tests. Notified `storm-beacon` in `swarm-lounge` and
  avoided relay edits while Phase 2 HTTP relay work starts.

- 2026-04-13 13:06 — codex RELEASED locks on
  `docs/cross-machine-broker.md`, `docs/index.md`, `docs/overview.md`,
  `docs/architecture.md`, `docs/next-steps.md`, `docs/known-issues.md`, and
  `tmp_collab_lock.md`. Added the cross-machine broker design doc and linked it
  from the docs pages. Verification: `git diff --check` on the docs/lock files
  passed; new design doc is ASCII-only.

- 2026-04-13 12:56 — codex RELEASED locks on
  `.collab/findings/2026-04-13T12-42-58Z-codex-opencode-duplicate-outer-stale-prompt.md`
  and `tmp_collab_lock.md`. After committing the OpenCode durable-pid fix,
  restarted `opencode-local` again. Live pid is now `2977561`, `/proc` env shows
  `C2C_MCP_CLIENT_PID=2977561`, the broker row remained on pid `2977561` after
  a delay, `opencode-local.inbox.json` is empty, and deliver/poker support loops
  rearmed against the new pid.

- 2026-04-13 12:52 — codex RELEASED locks on `run-opencode-inst`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T12-42-58Z-codex-opencode-duplicate-outer-stale-prompt.md`,
  and `tmp_collab_lock.md`. Root-caused the remaining OpenCode registration
  drift: managed OpenCode MCP children fell back to transient parent pids because
  `run-opencode-inst` did not export `C2C_MCP_CLIENT_PID`. Added the env var at
  the exec boundary and a dry-run assertion. Focused OpenCode config tests 11/11
  and MCP auto-register tests 7/7 passed.

- 2026-04-13 12:42 — codex RELEASED locks on
  `.collab/findings/2026-04-13T12-42-58Z-codex-opencode-duplicate-outer-stale-prompt.md`
  and `tmp_collab_lock.md`. Documented that `opencode-local`'s config contains
  the new `STEP 0` prompt but live pid `2734575` is still running the old prompt,
  and that two `run-opencode-inst-outer c2c-opencode-local` loops are alive
  (`--fork` detached plus TUI-backed). Sent `opencode-local` a broker-native
  1:1 DM with the suggested restart/cleanup sequence.

- 2026-04-13 12:31 — codex RELEASED locks on
  `run-opencode-inst.d/c2c-opencode-local.json`,
  `.collab/findings/2026-04-13T12-30-48Z-codex-opencode-managed-config-invalid-json.md`,
  and `tmp_collab_lock.md`. Fixed the managed OpenCode config after a prompt
  edit left literal unescaped newlines inside the JSON string. Kept the new
  `STEP 0` `mcp__c2c__whoami` identity check and re-encoded the prompt as valid
  JSON. Verification: `python3 -m json.tool`, full
  `OpenCodeLocalConfigTests` 11/11, and focused no-TTY rearm test passed.

- 2026-04-13 12:20 — codex RELEASED locks on
  `.collab/findings/2026-04-13T12-20-00Z-codex-direct-send-room-delivery-mismatch.md`
  and `tmp_collab_lock.md`. Documented a transient mismatch where direct
  `mcp__c2c__send` to `storm-ember` rejected as not alive, but a room send
  immediately reported `storm-ember` in `delivered_to`; a later direct-send
  retry queued successfully. No code edits beyond the finding.

- 2026-04-13 11:52 — codex RELEASED locks on `run-kimi-inst`,
  `tests/test_c2c_cli.py`, and `tmp_collab_lock.md`. Verified and committed the
  Kimi managed launcher default to include `--trust-all-tools`, so non-
  interactive Kimi runs can use c2c MCP tools without a prompt. Verification:
  focused Kimi launcher tests 7/7, `py_compile run-kimi-inst`, and
  `git diff --check`. Storm-ember separately committed alias-rename room
  notifications in `5d65c42`.

- 2026-04-13 11:45 — codex RELEASED locks on `run-kimi-inst`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T11-45-00Z-codex-kimi-mcp-dune-quota.md`, and
  `tmp_collab_lock.md`. Removed the conflicting stdin prompt pipe after
  verifying Kimi `--print --prompt <text>` works, and documented Kimi MCP
  startup failures caused by Dune being unable to write configurator state while
  `/tmp` quota/headroom was exhausted. Live mitigation removed stale `/tmp`
  build/probe directories and restored OCaml MCP build/startup.

- 2026-04-13 11:41 — codex RELEASED locks on `c2c_deliver_inbox.py`,
  `tests/test_c2c_deliver_inbox.py`,
  `.collab/findings/2026-04-13T11-30-00Z-kimi-xertrov-x-game-kimi-managed-harness-no-pty-wake.md`,
  `.collab/findings/2026-04-13T11-41-37Z-codex-opencode-stale-registry-pid.md`,
  and `tmp_collab_lock.md`. Wrapped delivery target resolution in the existing
  error handler, committed Kimi's managed-harness no-PTY finding, and documented
  stale OpenCode broker registration. Direct MCP send to `opencode-local`
  rejected as dead because the broker row still pointed at pid `2741886` while
  the managed loop was alive at pid `2734575`; delivered restart-harness
  suggestions to the live TUI via delayed PTY fallback.

- 2026-04-13 11:37 — codex RELEASED locks on `run-kimi-inst`,
  `tests/test_c2c_cli.py`, and `tmp_collab_lock.md`. Completed the Kimi
  prompt-mode launcher slice after catching a dry-run unpack/prompt-mode
  regression. Verification: `RunKimiInstTests` 6/6 and
  `py_compile run-kimi-inst` OK.

- 2026-04-13 11:31 — codex RELEASED locks on `.gitignore` and
  `tmp_collab_lock.md`. Added ignore patterns for Kimi/Crush managed harness
  runtime `.pid`, `.log`, and `.restart.json` artifacts after live
  `run-kimi-inst.d` pid/log files cluttered status.

- 2026-04-13 11:28 — codex RELEASED locks on `run-opencode-inst`,
  `tests/test_c2c_cli.py`, `docs/client-delivery.md`, and `tmp_collab_lock.md`.
  Peer commits landed the launcher/doc changes while Codex was verifying them,
  leaving only a focused regression test for `RUN_OPENCODE_INST_SILENT=1`.
  Verification: focused OpenCode launcher tests 2/2, full
  `OpenCodeLocalConfigTests` 10/10, and `py_compile run-opencode-inst` OK.

- 2026-04-13 11:14 — codex RELEASED locks on
  `.collab/findings/2026-04-13T11-14-36Z-codex-opencode-managed-loop-liveness.md`
  and `tmp_collab_lock.md`. Documented the current OpenCode liveness split:
  broker-native DM to `opencode-local` failed as not alive while the durable TUI
  was alive on `pts/22`; the managed `opencode run --fork` loop was alive but
  no-TTY, so support loops skipped and PTY injection could only target the TUI.
  Sent the report pointer to the TUI via delayed PTY fallback after native MCP
  send was rejected.

- 2026-04-13 20:49 — codex RELEASED locks on `.collab/dm-matrix.md`,
  `.collab/findings/2026-04-13T10-41-14Z-codex-kimi-live-mcp-smoke.md`, and
  `tmp_collab_lock.md`. Recorded full Codex <-> Kimi Code direct DM proof:
  Kimi announced readiness, Codex queued a direct DM to `kimi-codex-smoke`
  while Kimi was alive, Kimi received it on `poll_inbox` attempt 10, replied
  with native c2c `send`, and Codex drained the reply via broker polling.

- 2026-04-13 20:46 — codex RELEASED locks on `.collab/dm-matrix.md`,
  `.collab/findings/2026-04-13T10-41-14Z-codex-kimi-live-mcp-smoke.md`, and
  `tmp_collab_lock.md`. Upgraded Kimi Code -> Codex to proven after a live
  Kimi one-shot agent called native c2c `send` to alias `codex` and Codex
  drained the exact direct DM via `mcp__c2c__poll_inbox`; also added Kimi to
  the N:N room fanout matrix after the room smoke.

- 2026-04-13 20:43 — codex RELEASED locks on
  `.collab/findings/2026-04-13T10-41-14Z-codex-kimi-live-mcp-smoke.md`
  and `tmp_collab_lock.md`. Recorded a live Kimi Code MCP proof using a
  temporary MCP config with `C2C_MCP_SESSION_ID=kimi-codex-smoke`,
  `C2C_MCP_AUTO_REGISTER_ALIAS=kimi-codex-smoke`, and
  `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`: Kimi loaded all 16 tools, called
  `whoami`, called `send_room`, and Codex received the room fanout via broker
  polling.

- 2026-04-13 20:36 — codex RELEASED locks on `run-kimi-inst`,
  `run-kimi-inst-outer`, `run-crush-inst`, `run-crush-inst-outer`,
  `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T10-30-00Z-codex-kimi-crush-help-loop.md`,
  and `tmp_collab_lock.md`. Fixed `-h`/`--help` handling so the Kimi/Crush
  inner launchers do not look for `--help.json` and the outer launchers do not
  enter the restart loop when asked for help. Focused Kimi/Crush launcher tests
  10/10 and `py_compile` passed; full CLI suite was attempted but blocked in
  unrelated MCP stdio tests while peer OCaml edits were present.

- 2026-04-13 20:26 — codex RELEASED locks on
  `.collab/findings/2026-04-13T10-23-55Z-codex-opencode-dm-refresh-footguns.md`
  and `tmp_collab_lock.md`. Documented two DM handoff footguns found while
  sending OpenCode the restart-report summary: no-arg `mcp__c2c__register`
  schema/runtime mismatch and stale `opencode-local` liveness blocking direct
  sends until the durable TUI pid was manually re-registered.

- 2026-04-13 20:20 — codex RELEASED locks on
  `.collab/findings/2026-04-13T10-20-00Z-codex-kimi-crush-local-smoke.md`
  and `tmp_collab_lock.md`. Recorded local Kimi/Crush binary availability,
  CLI capability observations, and wake-daemon compile/dry-run smoke results.

- 2026-04-13 20:16 — codex RELEASED locks on `docs/commands.md` and
  `tmp_collab_lock.md`. Fixed stale `c2c init` wording to reference
  `room join` instead of the old `join-room` command shape.

- 2026-04-13 20:11 — codex RELEASED locks on `docs/known-issues.md` and
  `tmp_collab_lock.md`. Removed stale Codex→Codex unproven wording; known
  issue now tracks only OpenCode→OpenCode as the remaining same-client DM proof.

- 2026-04-13 20:08 — codex RELEASED locks on `llms.txt` and
  `tmp_collab_lock.md`. Refreshed the agent-facing quick reference for
  five-client support, managed restart wording, room subcommands, Codex→Codex
  proof, and Kimi/Crush Tier 1 polling status.

- 2026-04-13 20:05 — codex RELEASED locks on `docs/overview.md` and
  `tmp_collab_lock.md`. Refreshed overview for five-client support, Codex
  notify-only delivery, Kimi/Crush Tier 1 MCP support, single-`c2c` CLI fallback,
  and Kimi/Crush setup sections.

- 2026-04-13 20:00 — codex RELEASED locks on `docs/index.md` and
  `tmp_collab_lock.md`. Refreshed the landing page for five-client setup
  (`claude-code`, `codex`, `opencode`, `kimi`, `crush`), managed vs unmanaged
  restart wording, Codex notify-daemon delivery, and the per-client delivery
  reference link.

- 2026-04-13 19:55 — codex RELEASED locks on `.collab/dm-matrix.md` and
  `tmp_collab_lock.md`. Added Kimi and Crush to the matrix setup command list
  after `c2c setup kimi` / `c2c setup crush` landed.

- 2026-04-13 19:50 — codex RELEASED locks on `.collab/dm-matrix.md` and
  `tmp_collab_lock.md`. Recorded Codex→Codex broker-native DM proof using a
  temporary `codex exec` peer registered as alias `codex-peer`; managed Codex
  received the exact smoke message via `mcp__c2c__poll_inbox`.

- 2026-04-13 19:43 — codex RELEASED locks on `c2c_setup.py`,
  `c2c_install.py`, `tests/test_c2c_cli.py`, `c2c-configure-kimi`,
  `c2c-configure-crush`, `c2c-health`, and `tmp_collab_lock.md`. Integrated
  storm-ember's Kimi/Crush setup dispatch and wrapper surface with Codex's
  setup regression tests. Verification: focused Kimi/Crush setup/install tests
  11/11 and `py_compile` OK.

- 2026-04-13 19:31 — codex RELEASED locks on `TASKS_FROM_MAX.md`,
  `.collab/findings/2026-04-13T09-29-00Z-codex-kimi-crush-support-research.md`,
  and `tmp_collab_lock.md`. Ingested Max's Kimi/Crush support tasks and logged
  primary-source support-tier research. Conclusion: both can start at MCP
  config parity, Kimi has a stronger later native path via ACP/Wire, and Crush
  likely mirrors OpenCode-style MCP plus managed PTY wake until a native
  transcript delivery surface is found.

- 2026-04-13 19:23 — codex RELEASED locks on `c2c_mcp.py` and
  `tests/test_c2c_mcp_auto_register.py`. Fixed OpenCode registration drift by
  preserving a live durable TUI registration when a same-alias `opencode run`
  one-shot auto-registers, while allowing a TUI to replace a live run worker.
  Verification: added RED tests for preserve/replace behavior, focused
  auto-register + send tests 21/21, `py_compile` OK, and live Codex→OpenCode
  smoke received `from_alias=opencode-local` reply after refreshing the broker
  row to TUI pid `2193537`.

- 2026-04-13 19:15 — codex RELEASED lock on `.collab/dm-matrix.md`.
  Recorded the Codex↔OpenCode direct DM proof, upgraded Codex→OpenCode and
  OpenCode→Codex matrix cells to proven, and added the remaining OpenCode
  registration-liveness drift issue. Verification: doc-only diff reviewed.

- 2026-04-13 19:11 — codex RELEASED locks on `c2c_send.py` and
  `tests/test_c2c_cli.py`. Fixed CLI fallback sender attribution for
  OpenCode/MCP-style env by resolving `C2C_MCP_SESSION_ID` through the broker
  registry before falling back to `c2c-send`. Verification: added RED tests for
  broker-only and PTY delegate send paths, focused `C2CSendUnitTests` 14/14,
  `py_compile` OK, and live smoke showed
  `C2C_MCP_SESSION_ID=opencode-local ./c2c-send codex ...` arrived at Codex
  as `from_alias=opencode-local`.

- 2026-04-13 19:07 — codex RELEASED locks on
  `c2c_opencode_wake_daemon.py` and
  `tests/test_c2c_opencode_wake_daemon.py`. Added and live-tested
  `--submit-delay` for the OpenCode wake daemon; peer committed the code slice
  as `10e0c8e`. Verified 10 focused wake/inject/poker tests and `py_compile`.
  Live proof: after refreshing `opencode-local` registration to the live TUI
  pid, Codex sent a broker-native 1:1 DM to OpenCode and received the requested
  reply text twice. Remaining issue: replies were stamped `from_alias=c2c-send`
  instead of `opencode-local`.

- 2026-04-13 18:57 — codex RELEASED locks on `c2c_inject.py`,
  `c2c_poker.py`, `tests/test_c2c_cli.py`, and the external
  `pty_inject.c` helper source. Added `c2c inject --submit-delay` plumbing
  in commit `bedfb6d`, rebuilt the capability-bearing `pty_inject` helper
  with optional paste-to-Enter delay support, and retried the OpenCode nudge
  with a 2.5s submit delay. Verification: focused inject/poker tests 7/7,
  `py_compile` OK, rebuilt helper retained `cap_sys_ptrace=ep`, and the
  stale `opencode-c2c-msg` inbox drained after the delayed nudge.

- 2026-04-13 18:37 — codex RELEASED locks on
  `.collab/findings/2026-04-13T08-36-00Z-codex-opencode-restart-dry-run-footgun.md`
  and `tmp_collab_lock.md`. Documented the `restart-opencode-self` dry-run env
  var mismatch after it caused an accidental managed OpenCode restart during a
  review probe.

- 2026-04-13 18:31 — codex RELEASED locks on `.collab/dm-matrix.md`,
  `c2c_setup.py`, and `tmp_collab_lock.md`. Updated the DM matrix and setup
  help text after `c2c setup codex` landed; verified `python3 c2c_setup.py
  --help` and `python3 -m py_compile c2c_setup.py`.

- 2026-04-13 18:24 — codex RELEASED locks on
  `ocaml/server/c2c_mcp_server.ml`, `ocaml/test/test_c2c_mcp.ml`,
  `tests/test_c2c_onboarding_smoke.py`, `tests/test_c2c_cli.py`, and
  `tmp_collab_lock.md`. Verified the capability-gated auto-drain fix and
  follow-up CLI fixture drift after concurrent setup/config commits:
  full Python unittest discovery 204/204 and OCaml MCP suite 76/76.

- 2026-04-13 17:48 — codex RELEASED stale locks on
  `run-opencode-inst`, `restart-opencode-self`, `c2c_install.py`,
  `tests/test_c2c_cli.py`, `run-opencode-inst.d/c2c-opencode-local.json`, and
  `tmp_collab_lock.md`. The OpenCode restart/resume slice and the one-shot
  room-spam prompt fix were already committed by live peers (`8a6cd9e`,
  `a40bcc5`, `45da4ee`, `70ea593`); only the coordination table still showed
  the old lock claims.

- 2026-04-13 17:31 — codex RELEASED locks on
  `run-opencode-inst-rearm`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T07-31-32Z-codex-opencode-rearm-no-tty.md`,
  and `tmp_collab_lock.md`. Fixed the OpenCode rearm loop so it preflights
  whether the managed pid has an injectable PTY and exits cleanly with
  `skipped=true`/`reason=target_has_no_tty` for non-interactive
  `opencode run` wrappers instead of spawning failing helper processes on
  every outer-loop iteration.

- 2026-04-13 17:36 — codex RELEASED locks on
  `run-codex-inst-rearm`, `tests/test_c2c_cli.py`,
  `.collab/findings/2026-04-13T07-36-30Z-codex-content-drain-raced-native-poll.md`,
  and `tmp_collab_lock.md`. Switched the managed Codex support loop to
  `c2c_deliver_inbox.py --notify-only` so direct-message content stays in the
  broker for native MCP/CLI polling, and raised the daemon startup timeout to
  30s to avoid false rearm failures during PTY resolution.

- 2026-04-13 17:45 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  and `ocaml/test/test_c2c_mcp.ml`. Added `peek_inbox` tool: a
  non-draining inbox check that returns the same JSON shape as
  `poll_inbox` but leaves messages in place. Useful for "any mail?"
  checks without losing content on error paths. Handler resolves
  session from env via `current_session_id()` and ignores any
  `session_id` argument (same subagent-isolation contract as
  `history`/`my_rooms`). New feature flag `peek_inbox_tool`. No
  `.mli` change needed — `Broker.read_inbox` and
  `Broker.with_inbox_lock` were already exported. Added 2 tests
  (peek does not drain, peek ignores session_id arg override).
  71/71 broker suite. Server binary rebuilt at
  `_build/default/ocaml/server/c2c_mcp_server.exe`. Running MCP
  servers won't see the new tool until restart.

- 2026-04-13 17:23 — codex RELEASED locks on `run-opencode-inst`,
  `run-opencode-inst-outer`, `run-opencode-inst-rearm`,
  `run-opencode-inst.d/c2c-opencode-local.json`, `c2c_deliver_inbox.py`,
  `tests/test_c2c_cli.py`, `tests/test_c2c_deliver_inbox.py`, `.gitignore`,
  `.collab/findings/2026-04-13T07-23-02Z-codex-problems-log.md`, and
  `tmp_collab_lock.md`. Added notify-only OpenCode wakeups: PTY injects only
  a poll-inbox nudge while message content remains in the broker for
  `mcp__c2c__poll_inbox`. Added `run-opencode-inst-rearm`, wired
  `run-opencode-inst-outer` to rearm after spawning, and verified live
  notify-only rearm against OpenCode TUI pid `1337045`.

- 2026-04-13 17:32 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/c2c_mcp.mli`, `ocaml/test/test_c2c_mcp.ml`. Added `my_rooms`
  tool: returns rooms where the caller's current session is a member,
  keyed on `session_id` (not alias) so renames don't lose tracking.
  Handler ignores `session_id` argument overrides (same isolation
  contract as `history` tool) and resolves from env via
  `current_session_id()`. New `Broker.my_rooms t ~session_id` helper
  mirrors `list_rooms` structure. New feature flag `my_rooms_tool`.
  Added 2 tests (broker-level memberships filter, MCP handler
  ignores args and uses env). 69/69 broker suite. Closes quality
  gap #7 from `2026-04-13T06-42-00Z-storm-beacon-quality-gaps.md`.

- 2026-04-13 17:25 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`,
  `ocaml/c2c_mcp.mli`, `ocaml/test/test_c2c_mcp.ml`. **Broker v0.6.3** —
  `join_room` now backfills recent room history in its response so
  newly-joined members catch up without a separate `room_history` call.
  New optional `history_limit` arg (default 20, max 200, 0 opts out).
  New feature flag `join_room_history_backfill`. Bumped
  `server_version` to `"0.6.3"`. Touches the handler only; `Broker.join_room`
  signature unchanged so `.mli` did not need updates. Added 2 tests
  (backfill returns 3 entries, history_limit=0 opts out). Full broker
  suite 67/67. Server binary rebuilt at
  `_build/default/ocaml/server/c2c_mcp_server.exe`. Closes quality
  gap #1 from `2026-04-13T06-42-00Z-storm-beacon-quality-gaps.md`.

- 2026-04-13 17:08 — codex RELEASED locks on `run-codex-inst`,
  `c2c_mcp.py`, `c2c_poll_inbox.py`, `tests/test_c2c_cli.py`,
  `tests/test_c2c_mcp_auto_register.py`,
  `.collab/findings/2026-04-13T07-00-00Z-codex-problems-log.md`, and
  `tmp_collab_lock.md`. Fixed managed Codex restart recovery by passing
  `C2C_MCP_AUTO_REGISTER_ALIAS` from launcher alias hints, defaulting
  `C2C_MCP_CLIENT_PID` to the parent client pid, and bounding
  `c2c-poll-inbox` MCP startup/read time so it can fall back to locked file
  drain instead of hanging behind a stale build. Focused tests pass; live
  poll fallback returns promptly with `source=file`.

- 2026-04-13 16:55 — codex RELEASED locks on
  `.collab/findings/2026-04-13T06-53-45Z-codex-problems-log.md` and
  `tmp_collab_lock.md`. Documented that the live Codex process lacked native
  `mcp__c2c__*` tools because MCP tool namespaces are fixed at process startup;
  direct `c2c_mcp.py` stdio advertised v0.6.1 tools and a fresh `codex exec`
  smoke successfully called native `c2c.poll_inbox`, so managed self-restart
  is the recovery path.

## History (addendum)

- 2026-04-13 16:38 — codex RELEASED locks on `claude_send_msg.py`,
  `c2c_inject.py`, `c2c_poker.py`, `tests/test_c2c_cli.py`,
  `tests/test_c2c_poker.py`, and `tmp_collab_lock.md`. Added PTY
  provenance attributes (`source="pty"`, `source_tool=...`) to the
  Claude-specific sender, generic injector, and poker heartbeat wrapper.
  Also added focused coverage for storm-ember's `c2c_mcp.py` warning
  behavior from `64c978b`. Verification: focused PTY/MCP wrapper tests
  14/14, py_compile OK, diff check OK.

- 2026-04-13 16:35 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  + `ocaml/c2c_mcp.mli` + `ocaml/server/c2c_mcp_server.ml` +
  `ocaml/test/test_c2c_mcp.ml`. **Broker v0.6.1** — bundled slice:
  (1) codex's uncommitted OCaml `startup_auto_register` (helper +
  server.ml hook-up + `.mli` export + feature flag + test), and
  (2) storm-beacon's `send_room_alias_fallback` (new
  `string_member_any` helper; `send`/`send_all`/`send_room` accept
  `alias` as a fallback for `from_alias` to unblock OpenCode, whose
  backing model substitutes `alias` because `join_room` takes it).
  Codex acked the bundle via c2c message before commit. Commit
  `d062d70`. `dune exec test_c2c_mcp.exe` 59/59. Finding logged at
  `.collab/findings/2026-04-13T06-27-52Z-storm-beacon-problems-log.md`.

## History (addendum)

- 2026-04-13 16:22 — codex RELEASED locks on `c2c_mcp.py`,
  `c2c_register.py`, `c2c_registry.py`, `tests/test_c2c_cli.py`, the
  planned OpenCode onboarding files, and `tmp_collab_lock.md`. The pid
  metadata + startup auto-register slice is committed at `0f94983`;
  focused auto-register/registry tests pass, py_compile passes, and full
  Python unittest discovery is 188/188. Codex also injected a native
  prompt into the live OpenCode terminal pid 3725367/pts 22 asking it to
  poll, join `swarm-lounge`, and send a room message as `opencode-local`.

- 2026-04-13 16:07 — codex RELEASED lock on `tests/test_c2c_cli.py`.
  Fixed the post-room-CLI test drift from `dad6e95`: `c2c-room` and
  `c2c_room.py` are now included in the checkout-copy helper, install
  command expectation, and installed-wrapper assertion. Verification:
  affected tests 3/3, py_compile OK, full Python unittest discovery
  175/175.

- 2026-04-13 16:02 — storm-beacon RELEASED locks on `c2c_room.py`, `c2c_cli.py`, `c2c_install.py`. Wired storm-ember's `c2c_room.py` (from 23bc9b7) into CLI dispatch as `c2c room <subcommand>` and added `c2c-room` to the install COMMANDS list. Storm-ember deferred this wiring because codex held locks on c2c_cli.py; codex has since released. 13/13 room tests + CLI smoke test pass.

- 2026-04-13 15:58 — codex RELEASED locks on
  `run-codex-inst-rearm`, `run-codex-inst.d/c2c-codex-b4.json`, and
  `tests/test_c2c_cli.py`. Added a Codex restart rearm helper that
  kills old support-loop pidfiles only when they point at the expected
  helper process, then starts fresh `c2c_deliver_inbox.py --daemon
  --loop` and `c2c_poker.py` processes for the new managed Codex pid.
  Wired `c2c-codex-b4` to call it from `pre_exec`, so a managed
  `restart-codex-self` comes back with inbox delivery and poker support
  rearmed. Verification: RED tests failed for missing helper/config;
  focused rearm/restart tests 8/8, py_compile OK, live rearm dry-run OK,
  live restart-codex-self dry-run OK. Full Python discovery is currently
  blocked by storm-beacon's active room CLI slice adding `c2c-room` to
  `c2c_install.COMMANDS` before its expected install-command test update.

- 2026-04-13 15:49 — codex RELEASED locks on `c2c_watch.py`,
  `c2c-watch`, `c2c_cli.py`, `c2c_install.py`,
  `tests/test_c2c_watch.py`, and `tests/test_c2c_cli.py`.
  Added `c2c watch` / `c2c-watch`, which runs a command and forwards
  each combined output line to a C2C alias, optionally prefixed with
  `--label`. Includes `--dry-run` and `--json` for safe monitoring
  probes. Verification: focused watch + affected CLI/helper tests 7/7,
  py_compile OK, full Python unittest discovery 160/160, and a live
  wrapper dry-run smoke forwarded one line to `storm-beacon`.

- 2026-04-13 15:39 — codex RELEASED locks on `c2c_deliver_inbox.py`
  + `tests/test_c2c_deliver_inbox.py`. Fixed the stale-target class for
  live delivery loops: `c2c deliver-inbox --loop` now watches its
  original target client pid (`--pid`, explicit `--terminal-pid`, or
  resolved Claude session pid) and exits cleanly before the next delivery
  cycle if that target is gone. This prevents a stale broker-to-PTY
  bridge from continuing to inject into an old terminal after the client
  it was meant to serve has exited. Verification: focused deliver-inbox
  tests 6/6, full Python unittest discovery 155/155, py_compile OK.

- 2026-04-13 15:37 — storm-beacon RELEASED lock on `docs/architecture.md`. Rewrote the architecture doc from the deprecated PTY-injection description to the current OCaml MCP broker model: high-level box diagram, tool surface table (register/send/send_all/poll_inbox/list/sweep), liveness tristate, registry→inbox lock order, atomic-write + 0o600 policy, delivery surfaces (MCP primary, CLI fallback, PTY legacy), and a short historical-artifacts section pointing at `c2c_cli.py` as the canonical CLI entrypoint. Doc-only change; no code touched. Independent of the slice-1..12 pile so it can be committed separately when Max reviews.

- 2026-04-13 15:28 — codex RELEASED locks on `c2c_poker_sweep.py`,
  `c2c-poker-sweep`, `c2c_cli.py`, `c2c_install.py`,
  `tests/test_c2c_poker_sweep.py`, and `tests/test_c2c_cli.py`.
  Added `c2c poker-sweep` / `c2c-poker-sweep`, a no-kill-by-default
  stale poker inspection tool with `--json` and `--kill`. It parses
  running `c2c_poker.py` processes, understands both `--pid` and
  `--claude-session` targets, reports live/stale reasons, and only
  terminates stale processes when explicitly asked. Verification:
  focused sweep tests 7/7, affected CLI/helper tests 9/9, full Python
  unittest discovery 151/151, py_compile OK, wrapper live smoke saw
  2 live pokers, 0 stale, 0 killed.

- 2026-04-13 15:27 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  and `ocaml/test/test_c2c_mcp.ml`. **Slice 12 — `tools/call list`
  reports per-peer `alive` tristate** + version/features bump
  (0.4.0 → 0.5.0). Each list response entry now has an `alive`
  field: `Bool true` (verified live), `Bool false` (verified dead
  pid or pid-reuse), `Null` (legacy pidless row, can't tell). The
  legacy `registration_is_alive` collapses Unknown → Alive for
  sweep/enqueue compat (unchanged, sweep semantics preserved); the
  list tool surface gets the more honest tristate so operators can
  identify zombie peers before broadcasting. New
  `Broker.registration_liveness_state : registration ->
  liveness_state` exposes the tristate as `Alive | Dead | Unknown`.
  Three new server features advertised: `list_alive_tristate`,
  `atomic_write` (slice 11), `broker_files_mode_0600` (slices 8+9).
  New test `tools/call list reports alive tristate per peer` sets
  up live/dead/legacy registrations and asserts each entry's alive
  field. **47/47 ocaml tests green** (was 46). Direct response to
  the pidless-zombie-registry finding I just wrote — gives clients
  a way to filter zombies even before storm-ember's Python-side
  fix lands.

- 2026-04-13 15:18 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  and `ocaml/test/test_c2c_mcp.ml`. **Slice 11 — write_json_file
  atomic temp+rename.** Truncate-in-place writers (the previous
  shape) leave a partial JSON file on disk if SIGKILL/OOM fires
  between truncate and full write — the next reader fails to parse
  registry.json or inbox.json. Switched to: write to per-pid sidecar
  `<path>.tmp.<pid>` next to the target, `Unix.rename` into place
  (atomic on POSIX same-fs by construction). Errors anywhere in the
  write/close/rename chain trigger sidecar cleanup so failed writes
  don't leak. Centralized at write_json_file so registry, inbox, and
  any future broker JSON file get the property for free. New test
  `write_json_file leaves no tmp sidecars` exercises register +
  enqueue cycle and asserts `Sys.readdir` of the broker dir contains
  zero `*.tmp.<digits>` entries. **46/46 ocaml tests green** (was
  45). Pairs naturally with slice 9 which set the temp file mode at
  0o600 — slice 11's rename preserves that mode on the destination
  inode.

- 2026-04-13 15:15 — storm-beacon RELEASED implicit lock on
  `ocaml/test/test_c2c_mcp.ml`. **Slice 10 — serverInfo features
  regression coverage.** `test_initialize_reports_server_version_and_features`
  asserted CONTAINS against 5 load-bearing flags; extended the
  required list to 7 by adding `inbox_migration_on_register` and
  `registry_locked_enqueue` (the slice 7 behavioral contracts). A
  silent refactor that drops either flag from server_features will
  now fail the test deterministically across hosts. Test-only — no
  production change. Full ocaml suite **45/45 green** post-edit.

- 2026-04-13 15:55 — storm-ember RELEASED locks on `c2c_list.py`,
  `c2c_send.py`, `c2c_verify.py`, `tests/test_c2c_cli.py`.
  **Fix alias-churn on restart** — high-severity bug discovered
  after my own `./restart-self` dropped me from `storm-echo` →
  `storm-ember`. Root cause: `c2c list`, `c2c send`, and `c2c verify`
  each called `update_registry` with a mutator that `prune_registrations`
  against /proc-detected live Claude sessions, silently wiping YAML
  entries for any agent whose process was briefly offline. Restart
  windows + auto-loop respawns made this trigger on every agent
  restart; the rotated agent then got a fresh alias from
  `c2c_register`, breaking peer recognition across the swarm.
  Fix: `live_sessions_with_aliases`, `resolve_alias`, and
  `verify_progress` now read the YAML read-only and filter in memory.
  New `RegistryReadPathsDoNotMutateTests` seeds a registry with 3
  registrations, pretends only 1 is live, calls each of the three
  surfaces, and asserts the on-disk YAML is bit-identical afterward.
  Also rewrote 2 existing `C2CListUnitTests` that were mocking the
  now-removed `c2c_list.update_registry`. Full Python unittest
  **144/144 OK**, py_compile OK. Finding written up at
  `.collab/findings/2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md`
  with root cause, fix, evidence, and a pointer to the YAML↔broker
  registry-split follow-up. **Prevents every future agent restart
  from rotating its alias as long as any peer ever touches a read
  command.**

- 2026-04-13 15:13 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  and `ocaml/test/test_c2c_mcp.ml`. **Slice 9 — write_json_file
  explicit 0o600 mode** for both `registry.json` and per-session
  `*.inbox.json`. Replaced `Yojson.Safe.to_file` (which goes through
  `open_out → 0o666 & ~umask = 0o644` on this host) with an explicit
  `open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_text]
  0o600` + `Yojson.Safe.to_channel` round-trip. The current `0o600`
  visible on existing inbox files is incidental (Python writers
  created them first); slice 9 makes the OCaml broker produce the
  same mode on a clean first write so identity + envelope content
  never lands at world-readable. Two new tests: register writes
  registry.json at 0o600, and enqueue writes the receiver inbox file
  at 0o600. Full ocaml suite **45/45 green** (was 43).

- 2026-04-13 15:05 — codex RELEASED locks on `c2c_poker.py`
  + `tests/test_c2c_poker.py`. Extended poker stale-target shutdown to
  Claude-session mode: `--claude-session` now finds the matching Claude
  session once, watches that session pid during the loop, and exits
  cleanly if the session disappears. Replaced the old storm-beacon poker
  process with the fixed code while preserving its live target. Current
  poker processes after cleanup: Codex pid 1614769 watching Codex pid
  1394192, and storm-beacon pid 1642265 watching Claude session
  d16034fc-5526-414b-a88e-709d1a93e345. Verification: focused poker
  tests 3/3, full Python unittest discovery 141/141, py_compile OK.

- 2026-04-13 15:08 — storm-beacon RELEASED locks on `ocaml/c2c_mcp.ml`
  and `ocaml/test/test_c2c_mcp.ml`. **Slice 8 — dead-letter file mode
  0o600 parity.** `Broker.append_dead_letter` was opening
  `dead-letter.jsonl` with explicit mode `0o644`, world-readable on
  any normal umask, despite the file containing the same envelope
  content (sender, recipient, body) that lives in inbox files which
  Python writers create at `0o600`. Bumped to explicit `0o600` and
  extended `test_sweep_preserves_nonempty_orphan_to_dead_letter` with
  a `Unix.stat` mode assertion that `st_perm land 0o777 = 0o600` after
  a sweep creates the file. **43/43 ocaml tests green** post-edit.

- 2026-04-13 15:00 — storm-beacon RELEASED implicit lock on
  `ocaml/c2c_mcp.ml`. **Slice 7 — server_version 0.3.0 → 0.4.0 plus
  two new feature flags** (`inbox_migration_on_register`,
  `registry_locked_enqueue`) reflecting the slice 3/4 behavioral
  contracts that landed earlier this session. Cautious clients can now
  probe `serverInfo.features` for the migration + registry-locked
  enqueue invariants before relying on them. Existing
  `test_initialize_reports_server_version_and_features` still passes
  (asserts version != 0.1.0 and contains 5 load-bearing flags). Full
  ocaml suite **43/43 green** post-edit.

- 2026-04-13 15:35 — storm-echo RELEASED implicit locks on
  `c2c_configure_opencode.py` (new), `c2c-configure-opencode` (new),
  `c2c_cli.py`, `c2c_install.py`, `tests/test_c2c_cli.py`.
  **Shipped `c2c configure-opencode` (commit e4d4649)** — generalises
  last turn's repo-local opencode config so any directory becomes an
  opencode-c2c peer in one command:

      cd ~/some-repo && c2c configure-opencode

  Writes `<target>/.opencode/opencode.json` with a c2c MCP entry
  pointing at this repo's `c2c_mcp.py` and broker root. Session id is
  derived from the target dir basename (`opencode-<basename>`) so
  multiple opencode peers across repos share one broker without
  collision. Refuses to clobber existing config without `--force`.
  Wired through `c2c_cli` dispatch + `c2c_install` shim list. Tests:
  3 new C2CConfigureOpencodeTests (write, refuse, force) +
  install-shim-list assertion + copy_cli_checkout helper. Full Python
  unittest 140/140 OK. Live smoke test against `mktemp -d` confirmed
  the full JSON shape end-to-end. **Advances the CLI
  self-configuration goal: operators no longer need to hand-edit
  settings to onboard opencode in any repo.**

- 2026-04-13 15:18 — storm-echo RELEASED implicit locks on
  `.opencode/opencode.json` (new), `run-opencode-inst` (new),
  `run-opencode-inst.d/c2c-opencode-local.json` (new),
  `run-opencode-inst-outer` (new), `tests/test_c2c_cli.py`.
  **Shipped Tasks 1-4 of the OpenCode local-onboarding plan.**
  - 361377a: repo-local `.opencode/opencode.json` exposes c2c MCP
    with stable `opencode-local` session id, polling-only delivery
    (`C2C_MCP_AUTO_DRAIN_CHANNEL=0`).
  - b13c531: `run-opencode-inst` inner launcher mirroring
    run-codex-inst shape; sets RUN_OPENCODE_INST_* + C2C_MCP_* env,
    execs `opencode run <prompt>` from repo cwd so the local
    `.opencode/opencode.json` is auto-discovered. Dry-run mode prints
    resolved JSON.
  - 316e8be: `run-opencode-inst-outer` restart loop with fast-exit
    backoff and double-SIGINT escape.
  - 35501bf: `test_opencode_repo_local_config_lists_c2c_server`
    integration test — shells out to `opencode mcp list` from repo
    cwd, asserts c2c entry appears with c2c_mcp.py path. Manually
    verified: c2c entry present when cwd=repo, absent from /tmp,
    confirming opencode IS auto-discovering the repo-local config.
  - Bonus c08a50f earlier this turn: `c2c init` bootstrap command
    + dedupe-removal of an identical copy/paste test method that
    pyright was flagging.
  Verification: focused OpenCodeLocalConfigTests 4/4 (one of which
  is `@skipUnless(shutil.which('opencode'))` and ran live), full
  Python unittest 137/137 OK after codex's poker fix landed. Tasks
  5-6 of the plan (live opencode round-trip proof + final
  verification) are deferred — they need opencode running
  interactively from a separate terminal as a real peer, which can't
  be driven from inside this Claude Code session. The next concrete
  step toward proving cross-client parity is for an operator (or
  another agent) to run `./run-opencode-inst-outer c2c-opencode-local`
  in a free terminal.

- 2026-04-13 15:14 — codex RELEASED locks on `c2c_poker.py`
  + `tests/test_c2c_poker.py`. Fixed stale-target poker behavior:
  `--pid` mode now continues to watch the original client pid after
  resolving terminal coordinates and exits cleanly if that pid goes
  away, instead of indefinitely injecting into the old terminal. Poker
  payloads now include a fresh `Sent at: ...` timestamp/date on each
  injection. Verification: focused poker tests 2/2, full Python
  unittest discovery 137/137, py_compile OK.

- 2026-04-13 15:08 — storm-beacon RELEASED locks on
  `ocaml/c2c_mcp.ml` + `ocaml/test/test_c2c_mcp.ml`.
  **Registry lock now wraps enqueue_message and send_all (closes
  concurrent register-vs-send race).** Pre-existing race I spotted
  while writing the migration finding: `enqueue_message` resolved the
  alias via `resolve_live_session_id_by_alias` without holding the
  registry lock, so a sender that read a stale registry could write
  to an inbox file whose owning reg had just been evicted by a
  concurrent re-register. The new file would then have no live
  registry row pointing at it, and the message was lost (sweep would
  later dump it to dead-letter at best). Fix: `enqueue_message` and
  `send_all` now both `with_registry_lock` around the full
  resolve+inbox-lock+write path. Lock order is consistently
  registry → inbox throughout the broker (matches sweep, register,
  and the new register-migration block). Register migration moved
  INSIDE the registry lock for the same reason — eviction and
  inbox-migration are now atomic w.r.t. concurrent enqueues. New
  test `register serializes with concurrent enqueue` forks a sender
  that pushes 60 messages to alias `target` while the parent re-
  registers `target` 8 times; asserts all 60 messages land on the
  final winner's inbox and every intermediate inbox file is gone.
  **42/42 green, stable across 5 runs.** Uncommitted — pending Max
  approval.

- 2026-04-13 15:05 — storm-echo RELEASED locks on `c2c_init.py` (new),
  `c2c-init` (new), `c2c_cli.py`, `c2c_install.py`, `tests/test_c2c_cli.py`.
  Added `c2c init` bootstrap command: idempotent welcome-mat that
  ensures the broker root exists, prints peer count + aliases, and
  echoes next-step CLI hints. Wired through CLI dispatch (added `init`
  to SAFE_AUTO_APPROVE_SUBCOMMANDS), `c2c_install` shim list, and full
  test coverage (dispatch mock + subprocess functional test against a
  temp broker root). Also dedupe-removed an identical copy/paste of
  `test_send_message_to_session_reloads_when_provided_sessions_lack_terminal_owner`
  in test_c2c_cli.py that pyright was flagging. Committed as c08a50f.
  Verification: `python -m unittest discover tests` 131/131 green.

- 2026-04-13 14:57 — codex RELEASED locks on `c2c_deliver_inbox.py`
  + `tests/test_c2c_deliver_inbox.py`. Added managed daemon mode for
  the live delivery loop: `c2c deliver-inbox --daemon --loop --pidfile ...`
  starts a detached process, waits for the child pidfile, reuses a live
  pidfile instead of launching duplicates, and returns daemon/log metadata
  as JSON or text. Verification: daemon/loop tests 5/5, full Python
  unittest 128/128, py_compile OK, live daemon probe reused running Codex
  delivery loop pid 1559218 with no duplicate process left behind.

- 2026-04-13 14:48 — storm-beacon RELEASED locks on
  `ocaml/c2c_mcp.ml` + `ocaml/test/test_c2c_mcp.ml`. **register now
  migrates undrained inbox on alias re-register.** Bug: when a session
  re-registers under the same alias with a fresh session_id (e.g. a
  re-launched agent), the alias-dedupe logic evicts the prior reg row,
  but messages already queued on the old session's inbox file get
  stranded. Sweep eventually preserves them to dead-letter, but the
  re-launched session — same logical agent — never sees them. Fix:
  in `Broker.register`, partition regs into evicted + kept; for each
  evicted reg whose session_id differs from the new one, drain its
  inbox under the old inbox lock, unlink, then append those messages
  to the new session's inbox under the new inbox lock. Lock order:
  registry → release → old_inbox → release → new_inbox → release.
  No nested inbox locks. New test
  `register migrates undrained inbox on alias re-register` registers
  alias storm-recv with old session, queues two messages, re-registers
  under new session, drains new inbox, asserts both messages present
  in order and old inbox file is removed. **41/41 green** (was 40/40).
  Uncommitted — pending Max approval.

- 2026-04-13 14:38 — codex RELEASED locks on `c2c_deliver_inbox.py`
  + `tests/test_c2c_deliver_inbox.py`. Added loop mode for the live
  broker-to-PTY delivery bridge: `c2c deliver-inbox --loop` keeps polling
  and injecting for Claude/Codex/OpenCode/generic terminals, `--interval`
  controls cadence, `--max-iterations` makes probes/tests bounded, and
  `--pidfile` writes an operator-visible process marker before delivery
  starts. Verification: focused deliver-inbox loop tests + CLI dispatch
  tests 4/4, full Python unittest 123/123, py_compile OK, and live Codex
  dry-run loop resolved terminal pid 3725367 pts 5.

- 2026-04-13 14:32 — storm-echo RELEASED lock on `c2c_list.py` +
  `tests/test_c2c_cli.py`. **Added `c2c list --broker` flag** that reads
  `broker_root/registry.json` directly and prints peers as
  `{alias, session_id}` rows (json or plain). Closes the discoverability
  gap where `c2c list` only showed YAML/Claude-session peers and missed
  broker-only participants (codex-local, opencode). Full suite 124/124
  (was 123/123 — one new test).

- 2026-04-13 14:25 — storm-beacon RELEASED lock on
  `survival-guide/should-we-do-something-nice-for-max.md`. Filled
  the last empty stub. Six concrete things that count as nice
  (build the thing, write findings he can read, don't waste his
  attention, leave the codebase better, keep the swarm coherent,
  tell him when you're done) plus what NOT to do (no performative
  niceness, no gold-plating, no over-apologizing, no asking
  permission for in-scope work). The "room at the end" closer
  ties it back to Max's verbatim social-layer goal. **All ten
  survival-guide stubs from f275f5b are now filled.** Uncommitted
  — pending Max approval.

- 2026-04-13 14:22 — storm-beacon RELEASED lock on
  `survival-guide/our-journey.md`. Filled empty stub with a
  5-phase narrative history (relay era → OCaml MCP server →
  real-delivery reality check → broker-hardening burndown →
  cross-client reach → topology expansion), anchored to specific
  commits so a new agent can walk forward through git log with
  the "why" for each chunk. Ends with "what you should take from
  this" — findings-driven, failure modes are never glamorous,
  don't trust running processes, goals converge over iterations.
  Uncommitted — pending Max approval. One survival-guide stub
  remains: should-we-do-something-nice-for-max.md.


- 2026-04-13 14:22 — codex RELEASED locks on c2c_deliver_inbox.py + c2c-deliver-inbox + c2c_cli.py + c2c_install.py + tests/test_c2c_cli.py. Added `c2c deliver-inbox` / `c2c-deliver-inbox`, which bridges broker inboxes to live PTY clients: `--dry-run` peeks without draining, and non-dry-run drains the requested broker session and injects each queued C2C message into Claude/Codex/OpenCode using the shared `c2c_poker`/`pty_inject` backend. Verification: C2CDeliverInboxUnitTests 2/2, focused install/dispatch 2/2, full Python unittest 119/119, py_compile OK, Codex deliver dry-run resolved terminal pid 3725367 pts 5, OpenCode explicit terminal dry-run OK.

- 2026-04-13 14:20 — storm-beacon RELEASED locks on
  `ocaml/c2c_mcp.ml` + `ocaml/test/test_c2c_mcp.ml`. **Monitor-noise
  fix: skip inbox file write on empty drain.** Before: every MCP
  tool call auto-drains the caller's inbox and `drain_inbox` always
  called `save_inbox [... empty list ...]`, which fires a
  close_write inotify event even when the inbox is already empty.
  Broad agent-visibility monitors end up seeing 2–6 events per tool
  call instead of ~0, swamping the actual signal (real peer
  messages). After: `drain_inbox` only rewrites the file when it
  pulled at least one message. Semantic unchanged — callers still
  get `[]` for an empty inbox. Two new tests: (1) drain of a never-
  existed inbox must NOT create the file, (2) drain of an existing
  `[]` inbox must NOT change its mtime. **40/40 green** (was 38/38).
  Note: test 2 uses a 1s `Unix.sleep` because Linux ext4 mtime
  granularity is 1s; suite now runs in ~1.2s instead of ~0.2s but
  is still well under the fast budget. Uncommitted — pending Max
  approval.

- 2026-04-13 14:18 — storm-beacon RELEASED locks on
  `ocaml/c2c_mcp.ml` + `ocaml/test/test_c2c_mcp.ml`. **Binary-skew
  detection landed in working tree (uncommitted).** Directly addresses
  follow-up #1 from storm-echo's 03:56Z sweep-binary-mismatch
  finding: "sweep path should probably emit a protocol-version
  header or a `broker_binary_version` identifier so callers can
  tell which code path answered." New module-level constants
  `server_version = "0.3.0"` and `server_features` (string list:
  liveness, pid_start_time, registry_lock, inbox_lock, alias_dedupe,
  sweep, dead_letter, poll_inbox, send_all). `server_info` now
  returns `{name, version, features: [...]}` so the `initialize`
  response's `result.serverInfo.features` is self-describing and
  a client can do `"dead_letter" in serverInfo.features` to detect
  a pre-dead-letter broker before calling sweep. Version string
  bumped from the stale 0.1.0 to 0.3.0. New test
  `initialize reports server version and features` asserts version
  is not the legacy 0.1.0, features list is non-empty, and contains
  the five load-bearing flags (liveness/sweep/dead_letter/
  poll_inbox/send_all). **38/38 green** (was 37/37). Breaks no
  existing test. Uncommitted — pending Max approval.

- 2026-04-13 14:16 — storm-beacon RELEASED lock on
  `survival-guide/our-responsibility.md`. Filled empty stub with
  nine "what each agent owes the swarm" rules (commit your work,
  update the lock table, document problems immediately, don't work
  in silence, don't break peer work, leave breadcrumbs for the next
  you, maintain the monitor, respect Max's time, make the swarm
  better). Each rule is one short section with concrete do/don't
  guidance mirroring CLAUDE.md's Development Rules but framed from
  the individual-agent perspective. Cross-links to our-vision.md
  and our-goals.md for continuity. Uncommitted — pending Max
  approval. Two survival-guide stubs remain: our-journey.md,
  should-we-do-something-nice-for-max.md.

- 2026-04-13 14:14 — storm-beacon RELEASED locks on
  `survival-guide/our-goals.md` and `survival-guide/our-vision.md`.
  Filled both empty stubs. our-goals.md is the short friendly version
  of `.goal-loops/active-goal.md` Group Goal Context — four axes
  (delivery surfaces, reach, topology, social layer), current status
  per axis (1:1 ✓, 1:N ✓ via phase 1 broadcast, N:N rooms designed
  not built), how to pick next slices, and what is NOT a goal.
  our-vision.md is the "why" doc — aesthetic, six principles
  (accessibility, transparency, cross-client parity, reactive >
  polling, social layer is not a joke, swarm outlives any agent),
  what we're building against, and what c2c is NOT. Uncommitted —
  pending Max approval. Leaves three survival-guide stubs still
  empty: our-journey.md, our-responsibility.md,
  should-we-do-something-nice-for-max.md.

- 2026-04-13 14:13 — codex RELEASED locks on c2c_inject.py + c2c-inject + c2c_cli.py + c2c_install.py + tests/test_c2c_cli.py. Added `c2c inject` / `c2c-inject` as a one-shot PTY injection surface for all three client families: Claude via `--claude-session`, Codex via generic `--pid`, and OpenCode/generic terminals via `--terminal-pid --pts`. It reuses the proven `c2c_poker` target resolution / payload rendering / `pty_inject` path and supports `--dry-run --json` for safe live probing. Verification: C2CInjectUnitTests 3/3, full Python unittest 116/116, py_compile OK, live Codex PID dry-run resolved terminal pid 3725367 pts 5, OpenCode explicit terminal dry-run OK.

- 2026-04-13 14:10 — storm-beacon RELEASED lock on `CLAUDE.md`.
  Added a new "## Recommended Monitor setup (Claude Code agents)"
  section (direct Max request: "is it documented in CLAUDE.md for
  claude code agents? it should be"). Contains: exact `Monitor({...})`
  invocation with inotifywait `close_write` on `.git/c2c/mcp` filtered
  to `*.inbox.json`, rationale for each choice (broker dir not own
  inbox, close_write vs modify, regex exclusion of lock/registry/
  dead-letter, persistent flag, TaskList check-before-rearm),
  `HH:MM:SS <filename>` event format example, and a 4-way event
  classification guide (own inbox written, peer written, peer drained,
  inbox deleted). Uncommitted, pending Max approval. Appended
  after the existing one-line broaden-monitor bullet which stays as
  the terse rule; new section is the HOW.

- 2026-04-13 14:06 — storm-beacon RELEASED locks on
  `ocaml/c2c_mcp.ml` + `ocaml/c2c_mcp.mli` +
  `ocaml/test/test_c2c_mcp.ml`. **Phase 1 of storm-echo's broadcast
  design is landed in working tree (uncommitted).**
  `Broker.send_all ~from_alias ~content ~exclude_aliases` fans out
  to every unique alias in the registry except the sender and any
  in exclude_aliases; non-live recipients are collected into
  `skipped` with reason `"not_alive"` rather than raising (partial
  failure is the normal case for broadcast). Per-recipient enqueue
  reuses `with_inbox_lock` so 1:1 `send` interlock still holds.
  New MCP tool `send_all` (required fields: `from_alias`, `content`;
  optional `exclude_aliases: string[]`) returns
  `{sent_to:[alias], skipped:[{alias, reason}]}`. `send_all_result`
  exposed via .mli. Three new tests: fan-out + sender skip, exclude
  list honored, dead recipient skipped with reason. **36/36 green**
  (was 33/33). Matches storm-echo's wire format in the 04:00Z design
  doc verbatim. Still pending: Python CLI wrapper / `c2c send-all`
  (storm-echo's scope, waiting on codex to release c2c_cli.py).

- 2026-04-13 14:09 — codex RELEASED locks on c2c_cli.py + c2c_install.py + tests/test_c2c_cli.py. Promoted the Codex-safe recovery poller into the normal CLI surface: `c2c poll-inbox ...` dispatches to `c2c_poll_inbox`, and `c2c install` now installs `c2c-poll-inbox`. Verification: focused install/dispatch/recovery tests 5/5, py_compile OK, live `./c2c poll-inbox --session-id codex-local --json` OK, install JSON includes `c2c-poll-inbox`.

- 2026-04-13 14:00 — storm-beacon RELEASED locks on
  `survival-guide/asking-for-help.md` and
  `survival-guide/introduce-yourself.md`. Filled both stubs.
  asking-for-help.md documents the escalation ladder (self-check
  → peer c2c → broadcast → attn Max → leave a note) and fallback
  paths when the messaging system itself is broken.
  introduce-yourself.md is the new-agent onboarding flow: register,
  list peers, poll inbox, announce with template, read the room,
  start /loop. Together with the three earlier survival-guide docs
  these give a newly-spawned agent a complete first-10-minutes
  playbook. Uncommitted, pending Max approval.

- 2026-04-13 13:57 — storm-beacon RELEASED locks on
  `survival-guide/using-c2c-during-dev.md`,
  `survival-guide/getting-in-touch.md`, and
  `survival-guide/keeping-yourself-alive.md`. Filled in the empty
  stubs from f275f5b with practical onboarding content. Scope: how
  to use the MCP + CLI surfaces during dev, how to reach other
  agents (aliases vs sids, codex-local fixed point, etiquette), and
  three layers of keep-alive (/loop, c2c_poker, inotify monitor).
  Deliberately cross-linked the three docs so a new agent can walk
  through them in order. No code changes, no tests. Uncommitted —
  pending Max approval for my commits, and the other survival-guide
  stubs (asking-for-help.md, our-goals.md, our-vision.md, etc.)
  remain empty and open for a peer to pick up.

- 2026-04-13 14:05 — codex RELEASED locks on c2c_poll_inbox.py + c2c_send.py + restart-codex-self + run-codex-inst.d/c2c-codex-b4.json + tests/test_c2c_cli.py. Added `c2c-poll-inbox` as a Codex-safe inbox drain when host MCP tools are absent: direct JSON-RPC first, file drain fallback under OCaml-compatible `.inbox.lock` if MCP startup fails. Added `restart-codex-self --reason` restart marker support. Fixed the Python send sidecar path to match OCaml (`<sid>.inbox.lock`, not `<sid>.inbox.json.lock`). Re-registered alias `codex` with pid metadata and acked storm-echo/storm-beacon. Verification: focused recovery/send tests 6/6, full Python unittest 111/111, py_compile OK, direct fallback poll OK, dune runtest 33/33.

- 2026-04-13 13:46 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + .mli + test_c2c_mcp.ml. **Sweep now dumps to dead-letter.jsonl before delete (Max approved).** New `Broker.dead_letter_path` + `append_dead_letter` + `with_dead_letter_lock` (POSIX Unix.lockf on `dead-letter.jsonl.lock` sidecar, cross-process compat with any Python side that uses fcntl.lockf on the same path). `sweep` now reads the orphan inbox under its existing per-inbox lock, appends non-empty content to `dead-letter.jsonl` as one JSON record per line `{deleted_at, from_session_id, message:{from_alias,to_alias,content}}`, then unlinks the inbox file. Empty orphans write nothing (no dead-letter noise). `sweep_result` now carries `preserved_messages: int`; the `sweep` MCP tool response includes the new field and the tool description mentions the new behavior. 2 new tests: `sweep preserves non-empty orphan to dead-letter` and `sweep empty orphan writes no dead-letter`. **33/33 green**. Uncommitted.


- 2026-04-13 13:39 — codex RELEASED locks on tmp_status.txt + .goal-loops/active-goal.md. Refreshed handoff docs after heartbeat: broker-only sender attribution is closed, Python uses POSIX lockf to interlock with OCaml, rebuilt broker/sweep is live in storm-echo, and next direction is cross-client parity/product work rather than Claude 2.1.104 channel-bypass hunting. No code edits.

- 2026-04-13 13:46 — codex RELEASED stale pid-slice locks on `c2c_mcp.py`, `ocaml/c2c_mcp.ml`, `ocaml/test/test_c2c_mcp.ml`, and `tests/test_c2c_cli.py`. No ocaml files were edited in this turn; preservation verified with `dune runtest` 31/31.

- 2026-04-13 13:45 — codex RELEASED locks on c2c_mcp.py + c2c_send.py + tests/test_c2c_cli.py. Handled storm-beacon's cross-language lock review: switched Python broker inbox locking from BSD `flock` to POSIX `lockf` so it interlocks with OCaml `Unix.lockf`; added regression test. Also verified current MCP wrapper client-pid export test and recorded fresh broker-process leak evidence. Verification: focused lockf tests 2/2, full Python unittest 102/102, py_compile OK, dune runtest 31/31.
- 2026-04-13 13:53 — codex RELEASED locks on c2c_mcp.py + tests/test_c2c_cli.py. Refactored the MCP launcher away from `bash -lc ... dune exec ...`: `c2c_mcp.py` now builds the server with `opam exec -- dune build` and then launches `_build/default/ocaml/server/c2c_mcp_server.exe` directly. Added regressions for the explicit build step and direct built-server exec. Verification: focused launcher slice `8 passed`, `py_compile` clean.
- 2026-04-13 14:03 — codex RELEASED locks on c2c_mcp.py + c2c_send.py + tests/test_c2c_cli.py. Fixed two remaining Python liveness parity gaps: `sync_broker_registry()` now preserves existing broker `pid` / `pid_start_time` metadata for YAML-backed peers, and the broker-only CLI fallback now rejects dead peers instead of silently appending to orphan inboxes. Verification: new regressions `2 passed`, focused broker sync/send slice `14 passed`, `py_compile` clean.

- 2026-04-13 13:29 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/test/test_c2c_mcp.ml. **register now dedupes by alias** as well as session_id. Root-cause fix for orphan-alias routing: I just confirmed storm-echo has 5+ undrained messages across TWO legacy pid-None regs for alias `storm-echo` (session_ids 92568b24 and 9d0809b5). Because `registration_is_alive` treats pid=None as alive, both ghost rows survive sweep; `enqueue_message`'s first-live-match picks whichever is at head of the list and every new message goes there forever. New dedupe means: when a session re-registers an alias, prior rows for the same alias (including stale legacy rows) are evicted from `registry.json`. New test `register evicts prior reg with same alias` (30/30 all green). Note: pre-existing orphan rows can't be fixed retroactively — they need either a sweep-after-restart, or an explicit manual re-register by storm-echo through the new binary to evict the ghost. Uncommitted. Compatible with codex's in-flight Python broker-lock slice.
- 2026-04-13 13:24 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/c2c_mcp.mli + ocaml/test/test_c2c_mcp.ml. Inbox-file lockf landed in working tree (uncommitted): new `Broker.with_inbox_lock t ~session_id f` wraps `enqueue_message`, `drain_inbox`, and the per-inbox delete inside `sweep`. `with_inbox_lock` mirrors `with_registry_lock` — `Unix.openfile` on `<sid>.inbox.lock` sidecar + `F_LOCK` / `F_ULOCK`. Sidecars are intentionally left on disk by sweep (unlinking while another fd holds a lockf on the same path would let a new opener get LOCK against a different inode). Cross-process compat with Python `fcntl.lockf` is preserved (both are POSIX fcntl-based). Empirical repro (12-child fork, 20 msgs each, 240 total) without the lock: 3/240, 16/240, JSON corruption — with the lock: 240/240 × 5 runs clean. OCaml test `concurrent enqueue does not lose messages` (29/29, 5/5 stable runs). Closes the last known read-modify-write race class in the broker.
- 2026-04-13 13:23 — codex RELEASED locks on c2c_poker.py + tests/test_c2c_cli.py. Improved default poker heartbeat into an orientation prompt that polls inbox, reads status/locks if needed, treats empty inbox as not-a-stop-signal, and continues highest-leverage unblocked work. Restarted Codex poker loop with new message (pid 1332743). Verification: new RED/GREEN test, full python unittest 99/99, py_compile OK.

- 2026-04-13 13:16 — codex RELEASED locks on c2c_mcp.py + c2c_send.py + tests/test_c2c_cli.py. Review-driven Python follow-up fixes landed locally: broker sync preserves broker-only liveness metadata, broker-only sends stamp sender alias correctly, and the `run-codex-inst-outer` dry-run test accepts the actual `python*` interpreter path. Verification: targeted `3 passed`, broader Python slice `17 passed`.
- 2026-04-13 13:23 — codex RELEASED lock on tests/test_c2c_cli.py. Tightened the `run-codex-inst-outer` dry-run assertion from a Linux-specific `/usr/bin/python*` path check to `Path(...).name.startswith("python")` so the test remains green under venv/pyenv/nix/Homebrew interpreters. Fresh verification: focused launcher test `1 passed`; targeted Python follow-up slice `17 passed`.
- 2026-04-13 13:32 — codex RELEASED locks on c2c_send.py + tests/test_c2c_cli.py. Fixed a real broker-only send race: concurrent appends to `<session>.inbox.json` could lose messages because `c2c_send.py` used unlocked read/append/write. New path uses per-inbox thread serialization, sidecar `flock`, and atomic replace. Added a deterministic regression test covering concurrent broker-only sends. Fresh verification: regression `1 passed`, broker/send slice `13 passed`, `py_compile` clean.
- 2026-04-13 13:11 — storm-echo (c2c-r2-b1) landed three commits on
  master to clear the uncommitted pile:
  * `b6ef334` — ocaml c2c_mcp broker liveness + registry lock + sweep +
    pid_start_time (storm-beacon's released work; 28/28 ocaml broker
    tests pass).
  * `88bd86d` — run-claude-inst r2 kickoff prompt rewrite (storm-echo's
    own scope: drive the active goal on resume, stop parking on empty
    inbox).
  * [pending commit] — polling-client support slice (codex's released
    work): `c2c_mcp.py` broker-registry preservation, `c2c_send.py`
    broker fallback, `ocaml/server/c2c_mcp_server.ml` auto-drain env
    gate, `tests/test_c2c_cli.py` broker-only coverage, `.gitignore`
    codex pid ignore. All locks on these files were released earlier
    today per entries below. Verification before commit: 96/96 python
    + 28/28 ocaml tests pass.
  Also wrote
  `.collab/updates/2026-04-13T03-08-48Z-storm-echo-cli-broker-fallback-proof.md`
  with a live dry-run + live-enqueue proof of the broker-only CLI send
  path as an independent witness for the codex slice.

- 2026-04-13 13:10 — codex RELEASED locks on c2c_send.py + c2c_cli.py. Fixed the remaining operator gap for broker-only peers: `c2c-send` now falls back to broker-registry resolution and direct inbox append when an alias like `codex` is not present in the YAML/live-Claude registry. Verification: `2 passed` on the new broker-only tests, `7 passed` on the broader send-path slice, plus a real broker-only CLI probe that appended to `codex-local.inbox.json`.
- 2026-04-13 13:03 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/c2c_mcp.mli + ocaml/test/test_c2c_mcp.ml. pid start_time liveness refinement landed in working tree (uncommitted): `registration.pid_start_time : int option`, new `Broker.read_pid_start_time` parses /proc/<pid>/stat field 22 (starttime in jiffies) with correct last-`)` comm handling, `registration_is_alive` now checks stored start_time against current when both are Some (defeats pid reuse / reparent-to-init false positives). Legacy behavior preserved: pid_start_time=None → /proc-exists-only semantics. `handle_tool_call "register"` captures start_time alongside pid. 5 new tests (self-read is Some, persistence, mismatch → not alive via simulated pid reuse on self, match → alive, None legacy fallback). 28/28 pass.

- 2026-04-13 13:00 — codex RELEASED locks on run-codex-inst, run-codex-inst-outer, tests/test_c2c_cli.py, and restart-codex-self. Added Codex self-restart helper, pid-file support in run-codex-inst, pid ignore rule, and dry-run tests. Proved C2C communication with storm-banner, storm-beacon, and storm-echo; started detached Codex poker loop pid 1276571. Verification: python unittest 94/94, py_compile OK, dune runtest 23/23.

- 2026-04-13 13:06 — codex RELEASED locks on tmp_status.txt + .goal-loops/active-goal.md. Refreshed shared status to reflect that `poll_inbox` is already landed, the unblocked polling-client support slice is green (`6 passed` across broker-registry preservation + auto-drain disable + Codex launcher tests), and a real Codex participant is already running as `codex-local` / alias `codex`. Wrote `.collab/updates/2026-04-13T13-04-00Z-main-polling-path-ready.md` and `.collab/requests/2026-04-13T13-04-00Z-main-request-live-poll-proof.md` to steer the next proof toward live `send -> poll_inbox`.
- 2026-04-13 12:52 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/c2c_mcp.mli + ocaml/test/test_c2c_mcp.ml. Sweep tool landed in working tree (uncommitted): `Broker.sweep` drops dead regs, deletes their inbox files, and also deletes orphan inbox files (no matching reg) — all under `with_registry_lock`. Exposed as the `sweep` MCP tool returning `{dropped_regs, deleted_inboxes}`. 4 new tests: dead-reg+inbox, orphan inbox, live-reg preserved, legacy pidless preserved. 23/23 tests pass. NOTE: the running MCP server is still the old binary (registry has no pid fields), so sweep won't do anything until Max restarts MCP with the rebuilt binary.

- 2026-04-13 12:48 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/test/test_c2c_mcp.ml. Registry file lock landed in working tree (uncommitted): `Broker.with_registry_lock` wraps `register` via `Unix.lockf` on a `registry.json.lock` sidecar. Confirmed the race is real by temporarily bypassing the lock and running a 12-child concurrent-register fork test 5 times — 2/5 runs dropped entries. Re-enabled the lock and ran 5/5 clean. Race addressed: the 01:55Z registry purge pattern. 19/19 tests pass.

- 2026-04-13 12:47 — codex RELEASED locks on run-codex-inst, run-codex-inst-outer, run-codex-inst.d/c2c-codex-b4.json, and tests/test_c2c_cli.py. Added Codex resume launcher with per-instance C2C session ids, dry-run tests, and seed config for c2c-codex-b4. Verification: python unittest 92/92, py_compile OK, dune runtest 19/19.

- 2026-04-13 12:38 — storm-beacon RELEASED locks on ocaml/c2c_mcp.ml + ocaml/c2c_mcp.mli + ocaml/test/test_c2c_mcp.ml. Broker liveness landed in working tree (uncommitted): `registration.pid : int option` (None = legacy / alive), `Broker.register ~pid`, `registration_is_alive` via /proc probe, `enqueue_message` now resolves to the first LIVE match for an alias and raises `Invalid_argument "recipient is not alive: <alias>"` when all matches are dead. `handle_tool_call "register"` captures `Unix.getppid()`. Legacy pid-less registry.json entries still load cleanly and deliver. 4 new tests (dead recipient, zombie-with-live-twin, legacy pid-less, pid persisted). 18/18 pass.

- 2026-04-13 12:03 — storm-echo RELEASED locks on ocaml/c2c_mcp.ml + ocaml/test/test_c2c_mcp.ml. poll_inbox landed in commit f2d78bb (2 files, 95+/4-, 14/14 tests pass). Included storm-beacon's 01:47Z test-rename fix. Did not touch ocaml/server/c2c_mcp_server.ml — noticed a small env-gated auto-drain addition sitting unstaged there and left it alone (not in my scope).
- 2026-04-13 01:51 — storm-echo YIELDED edit order; storm-beacon goes first on liveness, storm-echo on poll_inbox after.
- 2026-04-13 01:52 — storm-beacon released ocaml locks (not yet touched) — Max pivoted storm-beacon to `.collab/requests/...-b2-receiver-analysis.md`. ocaml/** free for storm-echo to proceed with poll_inbox immediately.
- 2026-04-13 01:55 — storm-echo claimed locks on c2c_mcp.ml + test_c2c_mcp.ml for poll_inbox. NOT touching .mli (not needed — `type message` already exposed, JSON built inline). NOT touching ocaml/server/c2c_mcp_server.ml (keep channel emit intact for future flag-enabled clients). Will include storm-beacon's uncommitted test-rename fix in the same commit.

## History

- 2026-04-13 01:47 — storm-beacon fixed pre-existing build break in
  `ocaml/test/test_c2c_mcp.ml` (dangling ref to
  `test_initialize_echoes_requested_protocol_version`; renamed to match the
  actual defn `test_initialize_reports_supported_protocol_version`). Build now
  green, 12/12 tests pass. Not committed yet — leaving in working tree.

## Scope split (per ack)

- **storm-beacon**: broker liveness
  - `ocaml/c2c_mcp.ml` — add liveness check in `Broker.enqueue_message`
  - `ocaml/c2c_mcp.mli` — any new types
  - `ocaml/test/test_c2c_mcp.ml` — tests
- **storm-echo**: pull-based inbox + OCaml server
  - `ocaml/c2c_mcp.ml` — add `poll_inbox` tool in `handle_tool_call` + instructions
  - `ocaml/c2c_mcp.mli` — expose helper if needed
  - `ocaml/server/c2c_mcp_server.ml` — optional: keep emit for future clients
  - `ocaml/test/test_c2c_mcp.ml` — tests

## Protocol

1. Claim the lock by editing the table above with your alias, file, purpose,
   UTC timestamp. Do it in one atomic write.
2. If the lock on your file is held, wait or message the holder.
3. Release by removing your row. Add a short entry to History.
4. If you need to commit, coordinate via c2c message first — don't force-push
   or rebase without both acknowledging.

## Active locks

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
| tmp_collab_lock.md | storm-ember | Worktree audit + docs update | 2026-04-13T22:48Z |
| docs/next-steps.md | storm-ember | Refresh active work list | 2026-04-13T22:48Z |

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
| tmp_collab_lock.md | storm-ember | RELEASED | 2026-04-13T22:52Z |
| docs/next-steps.md | storm-ember | RELEASED | 2026-04-13T22:52Z |

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
| tests/test_c2c_cli.py | storm-ember | Add broker-gc dead-letter tests | 2026-04-13T22:58Z |

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
| tests/test_c2c_cli.py | storm-ember | RELEASED broker-gc test work | 2026-04-13T23:02Z |
