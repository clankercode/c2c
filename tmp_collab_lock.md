# c2c Collaboration Lock (storm-beacon ↔ storm-echo)

Both sessions share `/home/xertrov/src/c2c-msg` as their working directory.
To avoid clobbering each other's edits, claim a lock on any file you're about to
modify. Release it immediately after you're done (committed or intentionally left
on disk).

## Active locks

| File | Holder | Purpose | Taken at |
|------|--------|---------|----------|
## History (addendum)

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
