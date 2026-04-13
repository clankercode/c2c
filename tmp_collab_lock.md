# c2c Collaboration Lock (storm-beacon ↔ storm-echo)

Both sessions share `/home/xertrov/src/c2c-msg` as their working directory.
To avoid clobbering each other's edits, claim a lock on any file you're about to
modify. Release it immediately after you're done (committed or intentionally left
on disk).

## Active locks

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|

## History (addendum)

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
