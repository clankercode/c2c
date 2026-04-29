**Author:** stanza-coder

# OCaml test coverage audit 2026-04-28

## Baseline

`opam exec -- dune runtest --force` — **3 pre-existing failures**, rest pass.

| Suite | Result | Notes |
|---|---|---|
| relay_identity / relay_bindings / relay_signed_ops / relay_enc / relay_remote_broker / relay_ratelimit / relay_auth_matrix / relay_e2e / relay_short_queue / mobile_pair / relay_observer / relay_e2e_integration / relay_observer_contract / device_pair / relay (~210 tests) | PASS | Relay is well-covered |
| c2c_name (2), c2c_role (35), peer_review (4), c2c_memory (29), wire_bridge (16), c2c_worktree (12), agent_refine (7) | PASS | |
| **c2c_mcp** (210 tests) | **FAIL** | `set_dnd on:"true" enables dnd` — broker DND boolean parsing regression |
| **c2c_stats** (9 tests) | **FAIL** | `path` — `expected …/13.md got …/23.md`. **Timezone bug**: test asserts UTC hour 13 but runs in `localtime` (AEST = UTC+10 → 23). Real bug in `c2c_sitrep.ml` path computation, not flaky. |
| **c2c_onboarding** (9 tests) | **FAIL** | `whoami mentions alias` — `register exits 0` actually exits 1 first; whoami can't surface an alias. End-to-end CLI smoke is broken. |

**Total OCaml LoC vs test LoC**: source `37,609` LoC across 53 files; tests `14,582` LoC across 25 files (~39% test-to-source ratio, but heavily concentrated in `test_c2c_mcp.ml` 7,400 + `test_c2c_start.ml` 1,952). Pull those two out and the rest of the codebase has `~28,200` source LoC vs `~5,200` test LoC (~18%).

## Risk hotspots (lowest coverage / highest impact)

### 1. `ocaml/relay_nudge.ml` — 144 SLoC / 0 test SLoC — broker idle-nudge scheduler

Drives every idle agent's automated re-engagement. Bugs here either (a) silently stop nudging (swarm dies quietly) or (b) over-nudge during DND (annoyance, false work-trigger storms).

- **Specific test #1** — `nudge_tick` skips DND-active sessions: build a fake `Broker.t` with two `registration` records, both idle past threshold; one with `dnd=true; dnd_until=None` (manual DND, no expiry), the other normal. Run `nudge_tick ~broker ~cadence_minutes:30.0 ~idle_minutes:25.0 ~messages:[{text="x"}]`. Assert only the non-DND alias gets a `Broker.enqueue_message` call (introspect via reading the inbox file or stub via in-memory broker). Catches a regression where the `is_dnd_active` `match` collapses (e.g. someone refactors `dnd: false` to default-true and forgets the explicit case) or where `dnd_until=Some past_ts` fails to clear correctly — both have shipped before in DND code paths (FAIL `set_dnd on:"true"` is live evidence).
- **Specific test #2** — `is_dnd_active` boundary: with `dnd=true; dnd_until=Some now` (exact equality), assert returns `false` per the documented "expired if now >= until_ts" comment. Catches off-by-one in DND expiry that would silently extend DND.
- **Specific test #3** — `start_nudge_scheduler` rejects `idle_minutes >= cadence_minutes` via `invalid_arg`. Catches a misconfig that would otherwise produce a tight nudge loop. One-line `Alcotest.check_raises`.

### 2. `ocaml/c2c_repo_fp.ml` — 58 SLoC / 0 test SLoC — broker root resolution

Every read/write to the broker funnels through `resolve_broker_root`. A bug here splits the swarm across two broker dirs (messages vanish into the wrong dir, registrations diverge). The 2026-04-26 broker-root migration to `$HOME/.c2c/repos/<fp>/broker` is the most recent broker outage class.

- **Specific test #1** — env precedence matrix: with `Unix.putenv` set up four scenarios (only `C2C_MCP_BROKER_ROOT`; only `XDG_STATE_HOME`; only `HOME`; none) and `Unix.unsetenv` unused vars, assert `resolve_broker_root ()` returns the path the docstring promises. Specifically: `C2C_MCP_BROKER_ROOT=/abs/foo` → `"/abs/foo"`; `C2C_MCP_BROKER_ROOT=rel` (relative) → `Sys.getcwd()/rel`; `XDG_STATE_HOME=/x` (no override) → `/x/c2c/repos/<fp>/broker`; only HOME → `$HOME/.c2c/repos/<fp>/broker`. Catches a regression in the env-precedence chain that would silently bifurcate the swarm — exactly the failure mode `migrate-broker` was built to fix. Pure function; trivial to test.
- **Specific test #2** — `repo_fingerprint` is a 12-hex-char prefix of SHA-256 of `remote.origin.url` when present. Stub `Git_helpers.git_first_line` via `C2C_GIT_FIRST_LINE_FIXTURE`-style env hook OR run inside `Sys.chdir` to a tmp dir initialized with `git init && git remote add origin https://example/foo`, then assert `String.length fp = 12` and `fp = "f1c5f3..." (precomputed)`. Catches accidental change to the digest input (e.g. someone adds branch name) which would silently re-key every operator's broker root and produce a one-shot mass message-loss event on next deploy.

### 3. `ocaml/cli/c2c_peer_pass.ml` — 471 SLoC / 0 test SLoC — anti-cheat for peer-PASS signing

This is the integrity boundary of the entire peer-PASS workflow. `validate_signing_allowed` is the only thing stopping self-PASS from infiltrating the audit trail. Currently zero tests.

- **Specific test #1** — `reviewer_is_author ~reviewer:"foo" ~sha`: stub via temp git repo with one commit authored as `Foo <foo@c2c.im>`; assert `reviewer_is_author ~reviewer:"foo" ~sha = true` (email local-part match), `~reviewer:"foo" ~sha` with author email `bar@c2c.im` and name `foo` returns `true` (name match), and `~reviewer:"foob"` with `foo@c2c.im` returns `false` (no false-prefix match). Catches the regression class where someone "simplifies" the local-part comparison to `String.starts_with` — `foo` would pass review on `foobar`'s commit, defeating anti-cheat.
- **Specific test #2** — `criteria_list_of_string`: pure function. Assert `criteria_list_of_string (Some "a, b ,c,, ") = ["a"; "b"; "c"]` (trim + drop empty), `criteria_list_of_string (Some "") = []`, `criteria_list_of_string None = []`. Catches subtle parsing changes that would let a reviewer claim phantom criteria (or, conversely, drop a real criterion under a typo).

### 4. `ocaml/tools/c2c_post_compact_hook.ml` — 460 SLoC / 0 test SLoC — post-compact context injection

Runs immediately after every Claude Code compact. If broken, the post-compact agent re-bites the channel-tag-reply trap and other reflex bugs that the verbatim reminder is *specifically* there to prevent (#317).

- **Specific test #1** — `truncate_to` boundary: assert `truncate_to "abc" 3 = "abc"` (no-op at exact length), `truncate_to "abcdef" 5 = "ab..."`, `truncate_to "x" 2 = "x"`, `truncate_to "abcd" 3 = "..."` — catches the next-tier bug where the `n - 3` becomes negative and `String.sub` raises, which would crash post-compact context emission silently (the wrapper swallows hook failures).
- **Specific test #2** — `active_slices ~alias:"stanza-coder" ~repo` orders alias-matched rows first. Set up a fake `.worktrees/` dir with three subdirs: `slice-foo-stanza-coder`, `slice-bar-other`, `slice-baz-other`, each a real `git init` + one commit. Assert the returned string starts with the stanza-coder row. Catches a regression where the partition direction inverts (peer slices pushed first), which would silently hide the agent's own active work under the budget cap on a busy swarm — exactly the failure mode the partition was added to prevent.

### 5. `ocaml/c2c_relay_connector.ml` — 800 SLoC / 0 test SLoC — relay outbox + reconnect

Bridges every cross-host message. Bug → cross-client sends silently fail (the #1 group-goal regression class). Hard to unit-test (network) but `parse_*` / queue-state-machine helpers within it are pure-shaped — worth at least one parser test per RPC envelope it consumes. **Lower-priority than 1–4 because it's mostly side-effecting**, but flagging as the largest untested module by SLoC.

## Already well-covered (do not duplicate)

- `relay.ml` (4806 SLoC) — `test_relay.ml` + 14 sibling relay test suites (~1900 LoC). Lease, register, signed ops, e2e, observer all have dedicated suites.
- `c2c_mcp.ml` (5640 SLoC) — `test_c2c_mcp.ml` (7400 LoC, 210 tests). Despite the 1 failing test, this is the most thoroughly covered module in the tree.
- `c2c_role.ml` (519 SLoC) — `test_c2c_role.ml` (483 LoC, 35 tests).
- `c2c_memory.ml` (582 SLoC) — `test_c2c_memory.ml` (315 LoC, 29 tests).
- `c2c_worktree.ml` (904 SLoC) — `test_c2c_worktree.ml` (272 LoC, 12 tests, all PASS) — gc_classify especially well covered.
- `c2c_wire_bridge.ml` (297 SLoC) — `test_wire_bridge.ml` (228 LoC, 16 tests).
- `peer_review.ml` (283 SLoC) — `test_peer_review.ml` (116 LoC, 4 tests on signing/serialization). Note: `peer_review.ml` is the artifact format; **`c2c_peer_pass.ml` is the CLI surface — the latter is the gap above**.

## Proposed slice

Slice name: `slice/peerpass-nudge-repofp-tests` (~150 LoC of new test code)

Add a single new file `ocaml/test/test_peer_pass_and_nudge.ml` plus a tiny `ocaml/test/test_repo_fp.ml`, wire into `ocaml/test/dune`. Highest-leverage tests, all pure or near-pure (no daemon spin-up):

1. **`reviewer_is_author` matrix** (peer_pass) — three asserts via tmp git repo with one commit. ~25 LoC. Closes the self-PASS infiltration vector.
2. **`criteria_list_of_string` parser** — three asserts, pure. ~10 LoC. Closes silent criteria-drop regressions.
3. **`is_dnd_active` + `nudge_tick` skips DND** (relay_nudge) — one fake `Broker.t` (use the existing `test_c2c_mcp.ml` broker-init fixture; extract to a shared helper if not already), three asserts. ~50 LoC.
4. **`resolve_broker_root` env precedence** — four `Unix.putenv` scenarios + assertions, with cleanup via `Fun.protect`. ~40 LoC.
5. **`repo_fingerprint` is SHA-256-prefix of remote.origin.url** — `Sys.chdir` to a `Filename.temp_dir`-built throwaway repo, set remote, assert exact 12-char hex. ~25 LoC.

Why this slice: each test directly closes an integrity- or reach-class regression (anti-cheat bypass, DND nudge-storm, swarm broker-bifurcation) that would otherwise only surface in production with painful diagnostics. All five tests are pure or filesystem-only — they fit alongside the existing `test_c2c_role`-style fixture pattern, no Lwt or sockets needed. The 200-LoC ceiling holds. Pre-requisite: file a separate fix for the timezone-dependent `c2c_stats path` failure (force `Unix.gmtime` instead of `localtime` in `c2c_sitrep.ml`'s path builder) — out of scope for this slice but worth flagging because it's the same root-cause class (untested hour-of-day assumption).
