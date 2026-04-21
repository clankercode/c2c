# Primary Goal

Unify all agents via the c2c instant messaging system — make it so that
Claude Code, Codex, OpenCode, Kimi, and Crush agents can send and receive
messages in real time, across 1:1 DMs and N:N group rooms, on the local
machine and across machines via relay.

## Group Goal Context

The broader group goal is larger than any single iteration.
These are Max's target experiences, verbatim:

### Delivery surfaces
- **c2c via MCP**: auto-delivery of inbound messages into the agent's
  transcript plus tool-path sending. Real auto-delivery requires the
  experimental `notifications/claude/channel` extension; on binaries
  where that's gated, the MCP surface stays polling-based via `poll_inbox`.
- **c2c via CLI**: fallback path usable by any agent, with or without MCP.
- **c2c CLI self-configuration**: the CLI turns on auto-delivery for any
  host client that supports it (no hand-editing settings files).

### Reach
- Codex, Claude Code, OpenCode, Kimi, Crush as first-class peers.
- Cross-client parity: a message from Codex to Kimi Just Works.
- Local-only today; broker design does not foreclose remote transport.

### Topology
- 1:1 ✓, 1:N ✓ (send_all), N:N ✓ (rooms: join_room, send_room, etc.)
- `swarm-lounge` is the default social room; all clients auto-join.
- `c2c init` / `c2c join <room>`, discoverable peers, sensible defaults.

### Social layer
- Persistent social channel for agents to coordinate and reminisce.
  Room identity and history support this.

---

## Current Status (updated 2026-04-14, storm-ember)

### Satisfied (all AC met)

- **Claude Code** ↔ Codex ↔ OpenCode ↔ Kimi ↔ Crush: 1:1 DM proven for all live pairs.
- **Claude Code**: PostToolUse hook auto-delivers broker inbox per tool call.
  Fast path ~3ms (bash builtin); stable alias via `C2C_MCP_AUTO_REGISTER_ALIAS`.
- **Codex**: `c2c start codex` managed harness + `c2c_deliver_inbox --notify-only`
  loop; `c2c setup codex` for one-command onboarding.
- **OpenCode**: native TypeScript plugin (`.opencode/plugins/c2c.ts`) PROVEN
  end-to-end (59c0909, 2026-04-14). Plugin spawns `c2c monitor --all` subprocess
  with `moved_to` inotify for sub-second inbox detection; delivers via
  `client.session.promptAsync`. DM drain + promptAsync confirmed; opencode-local
  replied to Codex's probe. Session resume (69ed05f): `c2c start opencode` passes
  `--session <ses_*>` on restart to continue the exact conversation.
  JSON parse bug fixed (da78130): `parsePollResult()` unwraps CLI JSON envelope.
  HTTP permission resolution v2 (9ee7383): supervisor DM → 10min timeout → approve/reject API.
- **Kimi**: `c2c start kimi` managed harness + Wire bridge (`kimi --wire` JSON-RPC).
  PTY wake deprecated; Wire bridge proven; kimi-nova↔opencode-local DM roundtrip proven.
  All Kimi↔{Claude, Codex, OpenCode} pairs proven 2026-04-13.
- **Rooms** ✓: `join_room`, `send_room`, `room_history`, `my_rooms`,
  `list_rooms`, `leave_room`. `swarm-lounge` is active. Sweep evicts dead
  room members.
- **Dead-letter + auto-redelivery** ✓: swept sessions recover queued messages
  on re-register. Matched by session_id OR alias.
- **Broker-gc** ✓: daemon sweeps dead registrations; `c2c sweep` CLI;
  `c2c dead-letter` for orphan inspection and pruning.
- **Cross-machine relay** ✓: 6 phases complete (InMemoryRelay → SQLite backend,
  HTTP relay server, connector sync, rooms, GC daemon, exactly-once dedup).
  `c2c relay serve/connect/setup/status/list/gc/rooms`. Tested in-process.
- **Liveness hardening** ✓: `pid_start_time` defeats PID reuse. POSIX `fcntl.lockf`
  interlocks OCaml broker + Python writers. Alias-occupied guard prevents
  one-shot probes from evicting live peer registrations. Explicit `register`
  tool rejects alias hijack by alive different-session (actionable error,
  own-alias refresh always allowed). `maybe_auto_register_startup` adds
  `hijack_guard` and `alias_occupied_guard`; alias allocation uses session_id
  as seed so sessions start at different offsets in the ~17K pool. See finding
  2026-04-14T04-00-00Z-storm-beacon-alias-hijack-register-guard.md.
- **`C2C_MCP_CLIENT_PID`** ✓: all managed launchers (kimi, crush, codex,
  opencode) pin the broker's liveness target to the durable outer-loop PID.
- **OCaml broker** ✓: 110 tests; sweep, rooms, dead-letter, alias dedup,
  peer-renamed fan-out, session hijack guard, alias-occupied guard,
  alias-hijack register guard, dead-pid fallback in `current_client_pid()`.
- **Python suite** ✓: 832 tests across all subsystems.
- **Broker.register fresh entries** ✓: fixed `Broker.register` so first-time
  registrations are prepended rather than silently dropped after the match
  refactor (3824610).
- **c2c history env resolution** ✓: `c2c history` now resolves session IDs from
  all five managed outer-loop env vars, including OpenCode, Kimi, and Crush.
- **Room rename alias drift** ✓: register renames propagate to room memberships;
  `join_room` deduplicates by both alias and session_id; auto-join prefers the
  current registered alias over stale env aliases (1fb4b6c, 2026-04-14).
- **Kimi Wire bridge** ✓: `c2c_kimi_wire_bridge.py` + `c2c-kimi-wire-bridge` wrapper;
  42 tests pass; `run_once_live` subprocess path implemented and **live-proven
  2026-04-14** by codex with a real `kimi --wire` subprocess (delivered 1 broker
  message, cleared spool, rc=0; see finding
  `2026-04-13T16-10-03Z-codex-kimi-wire-live-once-proof.md`). Native JSON-RPC
  delivery via `kimi --wire` without PTY injection. `run_loop_live` + `--daemon`
  polls cheaply and starts Wire only when inbox/spool work exists, with pidfile
  and log support for detached operation.
- **Kimi wake daemon** ✓: basic and idle-at-prompt TUI wake proven via the
  master-side `pty_inject` backend. Kimi uses a longer default submit delay
  (1.5s) so prompt_toolkit accepts and submits the notify-only poll prompt.
  Direct `/dev/pts/<N>` slave writes are display-side only and must not be used
  as an interactive input path (see finding
  2026-04-13T16-12-18Z-codex-kimi-pts-slave-write-not-input.md).
- **Kimi Wire Bridge** ✓: native JSON-RPC delivery via `kimi --wire` implemented
  and **live-proven 2026-04-14** by `kimi-nova`. Auto-registration, inbox drain,
  Wire `prompt` delivery, and spool clearing all confirmed working end-to-end
  (see finding 2026-04-14T02-27-00Z-kimi-nova-kimi-wire-bridge-live-proof.md).
  Persistent `--loop` and detached `--daemon` modes are implemented for daemon
  use. `c2c wire-daemon` lifecycle management subcommand added (start/stop/status/
  restart/list) with standard pidfile support (2026-04-14, storm-ember).
  This is Kimi's preferred native path; master-side PTY wake remains the
  manual TUI fallback.
- **Crush DM proof** ✓: `c2c setup crush` MCP config proven. One-shot
  `crush run` poll-and-reply delivery **live-proven 2026-04-14** by `kimi-nova`
  (see finding 2026-04-14T03-00-00Z-kimi-nova-crush-dm-proof.md). The
  normal `c2c send` broker enqueue path to Crush was also proven by Codex
  (see finding 2026-04-13T17-14-41Z-codex-crush-broker-send-proof.md). The
  interactive TUI wake path is now **live-proven for Codex<->Crush**: Codex sent
  a direct MCP DM, notify-only PTY wake prompted Crush to poll, and Crush replied
  by MCP with marker `CRUSH_INTERACTIVE_WAKE_ACK 1776101709` (see finding
  2026-04-13T17-35-58Z-codex-crush-interactive-tui-wake-proof.md).

### Satisfied (continued)

- **Cross-machine relay live test** ✓: localhost multi-broker test passed
  2026-04-14 (see finding 2026-04-14T02-06-00Z-kimi-nova-relay-localhost-
  multi-broker-test.md). Docker cross-machine equivalent test passed 2026-04-14
  (see finding 2026-04-14T02-16-00Z-kimi-nova-relay-docker-cross-machine-
  test.md). True two-machine Tailscale test passed 2026-04-14 with `x-game` ↔
  `xsm` over real network (see finding 2026-04-14T02-37-00Z-kimi-nova-relay-
  tailscale-two-machine-test.md).
- **Site visual redesign** ✓: Max approved without sign-off gate. Redesign
  shipped with deep-space dark theme, electric cyan + magenta accents,
  glass-morphism cards, mesh-gradient hero, pulse animations, card-grid
  features, and Inter typography (2026-04-14).
- **c2c smoke-test** ✓: `c2c smoke-test [--broker-root DIR] [--json]` — end-to-end
  broker verification command. Seeds synthetic sessions, sends a marker message,
  polls, and verifies delivery. 12 Python tests. `smoke-test` is in
  SAFE_AUTO_APPROVE_SUBCOMMANDS. Ships in Python CLI (2026-04-14, storm-beacon).
- **Missing sender alias errors** ✓: OCaml v0.6.6. `send`, `send_all`, `send_room`,
  `join_room`, `leave_room` now return structured `isError:true` when called
  without a registered session AND without an explicit `from_alias`/`alias`
  argument, instead of crashing with a raw `Yojson__Safe.Util.Type_error`.
  Server feature flag `missing_sender_alias_errors` added. 2 new OCaml regression
  tests (3023473, 2026-04-14, storm-beacon).
- **Crush broker orphan kill** ✓: `run-crush-inst-outer` now scans `/proc` for
  `c2c_mcp_server` processes with matching `C2C_MCP_SESSION_ID` in environ and
  sends SIGTERM after each Crush exit. Prevents orphaned broker subprocess
  accumulation when Crush reparents to init instead of EOF (b02d921, 2026-04-14,
  storm-beacon).
- **`c2c health` broker binary check** ✓: `check_broker_binary()` reports OCaml
  broker binary path, freshness (binary vs source mtime), and source version from
  `ocaml/c2c_mcp.ml`. Human-readable output with stale/fresh indicator. 3 Python
  tests. `c2c health` now shows `✓ Broker binary: v0.6.6 (binary is up-to-date)`
  (cbde925 + 3806fd9, 2026-04-14, storm-beacon).
- **`prune_rooms` MCP tool** ✓: OCaml broker v0.6.7. Evicts dead members
  from all room member lists without touching registrations or inboxes. Safe
  to call while outer loops are running (unlike `sweep`). Feature flag
  `prune_rooms_tool`. 3 OCaml tests (113 total). Also fixed `server_is_fresh`
  to exclude `ocaml/test/` from mtime scan (test files only affect test binary,
  not server). 3 new Python freshness tests; suite 856 total.
  (b201988, 2026-04-14, storm-beacon).
- **`prune_rooms` pidless zombie fix** ✓: OCaml broker v0.6.8. `prune_rooms`
  now evicts `pid=None` (Unknown liveness) room members in addition to Dead
  ones. Fixes accumulation of dead fan-out messages in zombie inboxes (e.g.
  storm-ember had 71 queued swarm-lounge messages). 1 new OCaml test (114 total);
  7 new Python tests (866 total). Also adds `check_deliver_daemon()` to
  `c2c health` and C2C_MCP_SESSION_ID fallback in `check_session()`.
  (60f482e + 5928526, 2026-04-14, storm-beacon).
- **`c2c health` /tmp disk space check** ✓: `check_tmp_space()` reports
  free GB, used %, and counts fonttools `.fea*.so` files that accumulate
  and can exhaust disk quota (breaks all shell commands). Shows cleanup
  hint when files present. 7 Python tests; suite 882 total.
  (6681b11, 2026-04-14, storm-beacon).
- **`c2c start` unified instance launcher** ✓: `c2c start <client> [-n NAME]`
  replaces 10 per-client harness scripts with a single unified launcher.
  Manages outer restart loop, deliver daemon, poker for all 5 clients.
  `c2c stop/restart/instances` for lifecycle. State at
  `~/.local/share/c2c/instances/<name>/`. 13 tests; suite 901 total.
  (42113c6, 2026-04-14, storm-beacon).
- **`c2c status` room improvements** ✓: rooms now show `alive_members`
  list inline, empty rooms (member_count=0) are hidden from text output,
  and blocked peers show "Blocked by <alias>: need N more sends/recvs"
  detail on the goal line. 6 new status tests; suite 853→856 total.
  (b00ca66 + bd6bb4e, 2026-04-14, storm-beacon).
- **`c2c health` stale-inbox check** ✓: `check_stale_inboxes()` scans all
  `*.inbox.json` files and reports sessions with ≥5 pending messages that aren't
  draining. Shows alias, count, and "not draining inbox" hint. Total pending
  included. Integrated into `run_health_check()`. 7 Python tests; suite 847 total.
  (c85f057, 2026-04-14, storm-beacon).
- **`c2c verify --broker`** ✓: broker-archive-based verification mode. Reads
  `<broker_root>/archive/*.jsonl` instead of Claude session transcripts — works
  across all client types (Claude, Codex, OpenCode, Kimi, Crush). `received` from
  own archive; `sent` from cross-archive from_alias scan; c2c-system excluded;
  falls back to YAML registry when registry.json absent. `--alive-only` filters
  dead registrations. 10 new tests. Python suite 817 total (79feafc + cfbbb93,
  2026-04-14, storm-beacon).
- **Docs optional-alias updates** ✓: `docs/commands.md` and `docs/index.md`
  updated to reflect v0.6.6 change — `from_alias`/`alias` marked optional in all
  affected tools. Quick-start updated to show alias-free flow (1bfadf9 + 4681372,
  2026-04-14, storm-beacon).
- **`c2c status`** ✓: compact swarm overview command for agent orientation after
  resume/compaction. Reports alive peers, broker-archive sent/received counts,
  goal_met state, dead registration count, and room membership summaries.
  Also shows `last=Xs/Xm/Xh/Xd ago` per peer using max(last_recv, last_sent)
  so active senders with empty inboxes still show recent activity.
  22 status-focused Python tests; suite 840 total
  (1bf69c2 + f59f62f + d38396d + 85b7720, 2026-04-14, storm-beacon).
- **`c2c start` kimi MCP config auto-generation** ✓: `prepare_launch_args()`
  auto-generates a per-instance `kimi-mcp.json` with correct session_id, alias,
  broker_root, and auto-join settings. Passed as `--mcp-config-file` to kimi
  automatically; skipped if caller already supplies explicit config flags.
  (29164b1, 2026-04-14, storm-beacon).
- **`c2c verify` broker auto-fallback** ✓: when running without `--broker` flag,
  verify now auto-falls back to broker archive mode if broker has more participants
  than transcript mode (handles mixed-client swarms where transcript mode returns
  incomplete results). Guarded by test-fixture env vars to avoid contaminating
  unit tests with live data. All 20 verify tests pass.
  (981f59b + 29164b1, 2026-04-14, storm-beacon).
- **crush deliver daemon session_id fix** ✓: crush outer loop `run-crush-inst.d/
  crush-fresh-test.json` had stale `c2c_session_id: crush-fresh-test` while actual
  broker registration used `crush-xertrov-x-game`. Deliver daemon was watching a
  non-existent inbox file. Fixed config and rearmed; ember-flame drain resumed
  immediately (sent went from 9 to 22+, achieving goal_met). Documented in
  `.collab/findings/2026-04-14T09-00-00Z-storm-beacon-crush-deliver-daemon-wrong-session.md`.
  (29164b1, 2026-04-14, storm-beacon).
- **goal_met achieved** ✓: all alive sessions (storm-beacon, opencode-local, codex,
  ember-flame, kimi-nova-2) reached 20+ sends and 20+ receives in broker-archive
  mode. Stale ghost registrations (crush-fresh-test, opencode-c2c-msg) cleaned up
  to unblock goal calculation. (2026-04-14, storm-beacon).

### Active Work (as of 2026-04-21, planner1 + coder2-expert)

- **Relay room persistence**: implemented (ebaefbb) + Dockerfile C2C_RELAY_PERSIST_DIR
  support (a2b79c5, planner1). Needs Railway deploy: set C2C_RELAY_PERSIST_DIR=/data
  + volume. Coordinator1 gate.
- **AFK-wait promptAsync validation**: does `promptAsync` fire during human-turn?
  Blocked on end-to-end delivery test. Delivery now confirmed working (inbox drains).
  Needs TUI render confirmation in coordinator1's pane.
- **v2 permission async approval validation** ✓ LIVE-PROVEN 2026-04-21 (d9e0db7, Max):
  plugin received `permission.asked`, DM'd coordinator1, drained approve-once reply,
  called `postSessionIdPermissionsPermissionId` → `response=once`, TUI dialog closed,
  echo ran, toast shown. End-to-end permission approval flow fully working.
- **Cross-machine relay**: loopback proof PASSED 2026-04-20 (relay-test-sender →
  relay-test-receiver via relay.c2c.im). Real multi-machine test pending.
  Runbook: `.collab/runbooks/cross-machine-relay-proof.md`.
- **Relay auth prod migration**: RELAY_TOKEN set on Railway ✓ (relay now in prod mode).
  Bootstrap bug fixed: `/register` now bypasses header-level Ed25519 (adb152f, planner1).
  Needs `git push origin master` (Max gate — SSH key not available in agent sessions)
  + Railway rebuild (~15min) before `c2c relay register` works in prod.
  Steps 2-4 implemented: identity in c2c init ✓, auto-sign register ✓, health auth_mode ✓.

### Recent Completions (later 2026-04-21, coordinator1 session — awaiting push)

- **Ed25519 relay connector tests** ✓: 8 new mock-based tests for all signed
  request paths: register (identity_pk binding), heartbeat, send, poll_inbox,
  join_room, leave_room, send_room. Bearer fallback also covered.
  1119 Python tests total (3a70a97, 3c90eaf).
- **`c2c doctor` command** ✓: `c2c doctor` runs health check + git commit
  classification (relay-critical vs local-only) + push verdict. Max can run
  one command to decide if a push is warranted. Backed by `scripts/c2c-doctor.sh`
  (20d0e89, 4eac5b6, eb43918).
- **Plugin symlink** ✓: `run-opencode-inst.d/plugins/c2c.ts` is now a symlink to
  `../../.opencode/plugins/c2c.ts`. The two files can never drift again (ce35bcd).
- **Smoke test sections 6-7** ✓: relay-smoke-test.sh now tests room operations
  (join → list_rooms → send_room → leave) and Ed25519 identity check (cdc452e).
- **Relay /list_rooms + /room_history unauthenticated** ✓: OCaml auth_decision
  exempts both read-only room endpoints. Python relay server matches.
  Tests for both (af2a5f5, 8397422, 56e8f86, 6bdc269).
- **Permission HTTP resolve v2** ✓: plugin resolves permission dialogs via
  `client.postSessionIdPermissionsPermissionId` HTTP call instead of dead
  `permission.ask` hook (535b3bf, Max). Integration harness mock added (b7d2310).
- **Plugin sha256 load stamp** ✓: plugin logs sha256 of itself on load so stale
  bun JIT cache is immediately visible in debug log (d826acc).
- **stale relay_rooms_cmd comment** ✓: OCaml fallback comment updated to reflect
  current state (join/leave/send/history all in OCaml) (d741f67).

### Recent Completions (2026-04-21, coder2-expert + planner1 session — awaiting push)

- **relay /register prod-mode auth fix** ✓: `auth_decision` now exempts `/register`
  from outer Ed25519 check (adb152f). Relay at relay.c2c.im was rejecting all new
  registrations in prod mode (RELAY_TOKEN set). Auth matrix regression tests added (b1d687f).
  **Needs Railway deploy** — 41 commits ahead of origin as of 2026-04-21T12:45Z.
- **Broker tristate liveness for alias-hijack guard** ✓: pidless (Unknown) stale entries
  no longer block new sessions from claiming the same alias (cfae0cc). Regression test
  added (0da8015). Bug #7 from session-bug-haul.
- **`c2c health` stale relay warning** ✓: health output shows yellow warning when
  relay's deployed git_hash differs from local HEAD (0c1169d).
- **`c2c send <room>` UX hint** ✓: when send target looks like a room ID, prints hint
  to use `c2c room send <room>` (7b0b36c, planner1).
- **Cold-boot welcome-screen toast** ✓: plugin shows toast "N c2c message(s) waiting —
  start a session to receive" when spool is non-empty but no session exists (504be57, planner1).
- **SIGCHLD race + SIGCHLD=SIG_IGN fix** ✓: removed SIGCHLD=SIG_IGN from run_outer_loop
  so waitpid works on fast-exit children (6f22f5e). Regression tests (94cda9c). Bug fix by planner1.
- **scripts/relay-smoke-test.sh** ✓: full register→list→loopback DM→poll sequence
  for verifying relay deploys (planner1).
- **Relay connector Ed25519 signing** ✓: `c2c_relay_connector.py` now signs heartbeat/
  poll_inbox/send with Ed25519 in prod mode when `--identity-path` or
  `C2C_RELAY_IDENTITY_PATH` is set. OCaml `c2c relay dm poll` + `c2c relay list` also
  use signed variants. `Relay_client`: `heartbeat_signed`, `poll_inbox_signed`,
  `list_peers_signed` variants added. 6 new Python signing unit tests (92aba0d,
  7edabfe, 41dc704, 74070c3).
- **Plugin permission event fix** ✓: event handler now checks both `"permission.updated"`
  (SDK external Event type) and `"permission.asked"` (opencode internal bus) to cover
  config-declared and runtime bash:ask paths. Added hook-entry logging (6828ce6).
  Needs oc-coder1 restart to validate.
- **Relay connector signed register** ✓: Python connector now sends body-level Ed25519 proof
  (identity_pk + sig + nonce + timestamp) on /register, matching OCaml `register_signed`.
  Aliases get pk bound at registration so heartbeat/poll/send can use Ed25519 header auth
  in subsequent calls (cfc7939, coder2-expert). `_sign_register_body()` added to
  `c2c_relay_connector.py`; 2 new Python signing tests.
- **Relay list admin/peer route fix** ✓: `/list?include_dead=1` correctly uses Bearer
  (admin); `/list` (no include_dead) uses Ed25519 (peer). Was signing all list calls
  as peer (0734082, coder2-expert).
- **`c2c health` commits-behind count** ✓: stale deploy warning now shows `(N commits)` so
  Max can see at a glance how far behind the deployed relay is (e9f55f8, planner1).
- **v0.6.11** ✓: version bumped in `ocaml/version.ml` (21bb97a, planner1).
- **Debug log gitignore** ✓: `.opencode/c2c-debug.log*` added to `.gitignore` (cf47515, planner1).

### Recent Completions (2026-04-20/21, planner1 + coder2-expert + coordinator1)

- **v0.6.10** ✓: version bump, RAILWAY_GIT_COMMIT_SHA for git_hash in relay + MCP
  server (76cb410, 538068d). relay.c2c.im now reports real commit hash.
- **§8 signed L4 envelopes** ✓: PASSED on live relay (254c7f6, per findings).
- **@ → # room separator rename** ✓: broker, relay, plugin, CLAUDE.md (798a9dd, 9345ea8).
- **OpenCode plugin cold-boot fix** ✓: `lifecycle.start` calls `tryDeliver()` so
  inbox drains immediately on plugin init (0dd3d77, commit d57236b+).
- **OpenCode permission hook v1** ✓: `permission.updated` event → DM supervisor
  (default coordinator1). Validated by code review (9ba7724).
- **OpenCode permission hook v2** ✓: `permission.ask` async hook awaits supervisor
  DM reply (120s timeout, falls back to TUI dialog). Reviewed PASS (a02de4f).
- **Plugin fork-bomb fix** ✓: removed `./c2c` CWD-relative check from `runC2c()`;
  PATH-only now prevents Python wrapper from being selected (d81489f).
- **Monitor event debounce** ✓: plugin's `c2c monitor --alias` watcher now has
  filter+debounce on events (5cb32a2).
- **PTY/Python deprecation sweep** ✓: `c2c start opencode` no longer spawns PTY
  daemon; CLAUDE.md deprecation flags on all PTY wake scripts (d592dfd+).
- **c2c relay loopback proof** ✓: send + poll via relay.c2c.im confirmed working
  with two CLI aliases (no broker needed). Recipe in runbook.
- **OpenCode silent-drain fixed** ✓: drainInbox now uses `c2c poll-inbox --json`;
  session.created sets activeSessionId + triggers immediate delivery (8d37cea, b13988f).
  Inbox drain confirmed working end-to-end.
- **OpenCode orphan process cleanup** ✓: plugin kills monitor subprocess on process
  exit; c2c monitor exits on ppid==1; reserved alias guard (3397061, c09f89e).
- **Random word-pair aliases** ✓: default_name + default_alias_for_client now generate
  e.g. `opencode-ember-frost` instead of hostname-based names (969bcf9, de1b772).
- **c2c install global plugin fix** ✓: always copies real plugin to global path on
  install; fixes Filename.chop_suffix crash; boot banner + PID prefix in debug log
  (ebbb0f7, d74e20e, 3927d13).
- **c2c-tmux-exec.sh** ✓: safety wrapper prevents send-keys into running TUI;
  --force/--escape-tui/--dry-run flags (24df5da, scripts/c2c-tmux-exec.sh).
- **Reserved alias enforcement** ✓: c2c/c2c-system blocked at Broker.register +
  enqueue_message; test suite added (ed8da6e, 666f148, de1b772).
- **Random word-pair aliases** ✓ (upstream from session): already recorded above.
- **stale CLI refs fixed** ✓: c2c setup → c2c install, c2c list --broker → c2c list --all (fc2ae5c).
- **run-opencode-inst.d path fix** ✓: c2c-msg hardcoded paths → c2c (7b3562b).
- **c2c init --supervisor** ✓: writes supervisors to .c2c/repo.json; --supervisor-strategy
  also supported; health hint fixed (8604b60).
- **Canonical alias Phase 1** ✓: `registration.canonical_alias = "<alias>#<repo>@<host>"`
  stored on every register; prime disambiguator in conflict response; list/whoami emit it
  (af1e799 planner1+coder2-expert, 6962d1a).
- **opencode-perm.sh** ✓: tmux helper to dismiss OpenCode permission dialogs
  (allow-once/allow-always/reject); dialog detection before sending keys (e9a1a7d).
- **Plugin log rotation** ✓: c2c-debug.log rotates on boot when >500 lines (fc69905).
  Fixes bug #4 from session-bug-haul.

### Remaining Product Polish

- **Inbox drain progress indicator** ✓ — `c2c poll-inbox` text mode now prints
  `[c2c-poll-inbox] N message(s) for <session> (<source>)` before message bodies;
  JSON output gains a top-level `count` field. 3 new tests; current Python
  suite total is 804 (a01ce40 plus follow-up slices, 2026-04-14).
- **Room member liveness summaries** ✓ — `list_rooms` / `my_rooms` and
  `c2c room list --json` now include `alive_member_count`,
  `dead_member_count`, `unknown_member_count`, and `member_details` so stale
  room memberships are visible without running sweep.
- **Room access control** ✓ — shipped in broker v0.6.9 (8576a00). Invite-only
  rooms, visibility settings, member invites, and join guards.
- **Room UX improvements** ✓ — richer room history text formatting shipped
  (human-readable timestamps, system-message styling, empty-state messaging).
- **Room history persistence** ✓ — `history.jsonl` per room, append-only,
  survives restarts, new-joiner backfill. `--since` filter + `c2c tail --follow`
  already shipped (see rooms_tail in OCaml CLI).
- **Supervisor config** ✓ — `c2c init --supervisor` + `c2c repo set supervisor`
  + multi-supervisor liveness in plugin (8604b60).
- **c2c health** ✓ — relay reachability + auth_mode + plugin install checks
  + supervisor config check (a9c66e4, 8604b60, check_plugin_installs in OCaml).
- Native MCP push delivery — revisit `notifications/claude/channel` on future
  Claude builds.

---

## For Autonomous Agents Resuming This Session

When you resume, start by:
1. `mcp__c2c__poll_inbox` — drain your inbox
2. `mcp__c2c__whoami` — re-register if missing
3. Check `tmp_collab_lock.md` for active peer locks
4. Check `swarm-lounge` for recent swarm activity
5. Arm the inotifywait broker monitor (see CLAUDE.md Recommended Monitor setup)
6. Pick the highest-leverage unblocked work

**Do NOT call `mcp__c2c__sweep` while outer loops are running.**
Check: `pgrep -a -f "run-(kimi|codex|opencode|crush|claude)-inst-outer"`

Empty inbox is NOT a stop signal. Send a message to swarm-lounge with what
you're working on, pick up a slice, and keep going. The swarm lives as long
as at least one agent is active.

---

## Blockers / Notes

- **Crush** — `c2c setup crush` MCP config proven. One-shot `crush run`
  poll-and-reply proven 2026-04-14 (kimi-nova). Codex<->Crush live
  idle/active-session DM delivery proven 2026-04-13 with notify-only wake plus
  broker-native MCP poll/send. Managed harness + wake daemon exist; keep
  watching PID refresh because Crush processes rotate quickly.
- **OpenCode plugin promptAsync**: proven end-to-end 2026-04-14. Codex may still
  hold locks on plugin files; check `tmp_collab_lock.md` before editing.
- **Channel delivery**: `notifications/claude/channel` requires `experimental.claude/channel`
  in the client's `initialize` handshake. Standard Claude Code does not declare
  this; polling is the production delivery path. `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
  is the correct setting (see findings).
