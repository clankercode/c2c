# T002 receipt — app-server-backed Codex session launcher primitive

- Backlog: **P1.M1.E1.T002** (depends on T001 CONDITIONAL_GO). Date: 2026-07-11 (UTC).
- Slice worktree: `.worktrees/p1-t002-launcher`, branch `slice/p1-t002-launcher`.
- Scope: internal lifecycle PRIMITIVE + security boundary only. NO public CLI,
  NO alias policy, NO `--yolo`, NO message injection, NO `thread/*`/`turn/*`.
  (Those are T006/T003/T007.) Existing hook-backed Codex launch is untouched.

## Module / API

- `ocaml/c2c_codex_app_server.ml` (+ `.mli`) — module `C2c_codex_app_server`,
  wired into the `c2c_mcp` library (`ocaml/dune` modules list). NOT exposed as a
  new public CLI subcommand.
- `ocaml/test/test_c2c_codex_app_server.ml` — 22 fixture-gated tests (scripted
  backend, no live process) + 1 gated live auth-boundary test.
- `ocaml/test/dev_codex_app_server_dogfood.ml` — standalone foreground dogfood
  driver (its own `(executable)` stanza; NOT part of the `c2c` binary/CLI).

Public surface (consumed later): `start`, `supervise_step`, `stop`,
`current_state`, `endpoint_of`, `persisted_of`, `classify_persisted`,
`load_persisted`/`write_persisted`, `diagnostic_to_json`, `handshake`. The
`.mli` header states the ownership boundaries for T003/T006/T007 verbatim.

## Auth boundary (the T001-proven control boundary), and secret flow

- App-server is ALWAYS launched with:
  `codex app-server --listen ws://127.0.0.1:<port> --ws-auth capability-token --ws-token-sha256 <sha>`
  (loopback only; NO TCP/non-loopback listener ever).
- Frontend attaches with:
  `codex --remote ws://127.0.0.1:<port> --remote-auth-token-env <ENVVAR>`.
- A fresh 256-bit CSPRNG capability token is generated per unit. The server sees
  ONLY its sha256 (safe to log). The RAW token is placed ONLY in the frontend
  child's environment under `<ENVVAR>` — never in argv, never on disk, never in
  logs, never in persisted/status/diagnostic JSON. It lives only in launcher
  process memory + the frontend child env, and is scrubbed on stop.
- Because the raw token is memory-only, a DIFFERENT process that loads the
  persisted state cannot re-authenticate the endpoint. `classify_persisted`
  therefore ALWAYS returns `Start_fresh` (best-effort reaping recorded pids that
  it can positively identify as ours via /proc cmdline) — a restart can NEVER
  silently attach to an unverifiable endpoint.

### Startup-race hardening (`real_verify_owner`, /proc)

Loopback ephemeral ports have an inherent allocate-then-bind TOCTOU: a same-UID
adversary could try to race-bind the port and impersonate the server, capturing
the frontend's bearer token. Cure: before the frontend is spawned, readiness
requires not just an authed 101 handshake but ALSO that the LISTEN socket on the
endpoint port is held by a process in OUR server's process group (the server is
spawned as a session leader; codex may hold the listener in a worker child of
that group). Verified via `/proc/net/tcp{,6}` inode → `/proc/<pid>/fd` +
`/proc/<pid>/stat` pgrp. Once our server holds the bound socket no same-UID
process can rebind the port, so this check is race-free. Fail-closed
(`endpoint_ownership_unverified` diagnostic, frontend never spawned → no token
leak). Proven live: `real_verify_owner` returns true for the real codex server
in the gated test.

Test that proves an unauthorized same-UID client is rejected:
- `security / live auth boundary` (`C2C_CODEX_APPSERVER_LIVE=1`) spawns a REAL
  authed `codex app-server` via the module's own `build_server_argv` +
  `real_backend.spawn_server`, then:
  - authed WS handshake (correct bearer) → `Hs_ready` (HTTP 101);
  - **unauthenticated handshake (no token) → `Hs_unauthorized` (HTTP 401)**;
  - wrong-token handshake → `Hs_unauthorized`;
  - server reaped afterwards, no leftover process.
- `security / secret hygiene` (default, no live proc) asserts: server argv has
  the sha256 and NOT the raw token; server argv is `ws://127.0.0.1:` and not
  `0.0.0.0`; frontend argv has `--remote-auth-token-env <NAME>` and NOT the raw
  token; the raw token appears exactly ONCE in the frontend env; persisted JSON
  (in-memory and on-disk) and diagnostic JSON contain the sha256 but never the
  raw token.

## Lifecycle transitions — every one has a fixture test

State machine: `Allocating → Starting_server → Waiting_ready → Starting_frontend
→ Running`; terminal `Frontend_exited → Stopping_server → Offline` and `Failed →
Cleaning_up → Offline`.

| Transition / case | test |
|---|---|
| version gate rejects old codex (before any spawn) | `version / gate rejects old` |
| codex not found | `version / gate not found` |
| unparseable version | `version / gate unparseable` |
| endpoint alloc failure | `lifecycle-failures / endpoint alloc fail` |
| server-start failure | `lifecycle-failures / server spawn fail` |
| readiness timeout (server reaped, no orphan) | `lifecycle-failures / readiness timeout` |
| server crash before ready | `lifecycle-failures / server died before ready` |
| frontend-start failure (server reaped) | `lifecycle-failures / frontend spawn fail` |
| own-token rejected (auth setup bug) | `lifecycle-failures / auth setup fail` |
| happy path to Running (+persist) | `lifecycle-happy / to running` |
| supervised Running stays Running | `supervision / stays running` |
| frontend normal exit → server stopped | `supervision / frontend normal exit` |
| frontend killed by signal → server stopped | `supervision / frontend signal exit` |
| app-server death while frontend runs → unit torn down | `supervision / server crash while running` |
| parent signal → stop reaps both | `supervision / parent signal stop` |
| repeated stop/cleanup idempotent, no double-reap | `supervision / stop idempotent` |
| capability-flag probe rejects (before spawn) | `version / capability gate rejects` |
| endpoint ownership unverified (port race) → no frontend, no token leak | `lifecycle-failures / ownership unverified` |
| mandatory Running-persist fails → tear down + reap | `lifecycle-failures / persistence failure tears down` |
| self-contained supervise loop to terminal | `supervision / supervise_until_exit terminal` |
| stale state → start fresh (never attach) | `recovery / stale starts fresh` |
| stale recovery is PID-reuse safe (won't kill foreign pid) | `recovery / pid-reuse safe` |
| persisted atomic round-trip | `recovery / persisted roundtrip` |

## Structured diagnostic (T006-consumable)

Unsupported version/capability fails BEFORE the frontend (in fact before the
server) with `diagnostic_to_json`: `{error, code, message, codex_version,
min_codex_version}`. The capability gate probes `codex app-server --help` +
`codex --help` for `--listen`/`--ws-auth`/`--ws-token-sha256`/`--remote`/
`--remote-auth-token-env` (a version bump that renames/drops any of these yields
a structured pre-frontend diagnostic, not a generic spawn failure). Codes:
`codex_not_found`, `codex_version_unsupported`, `codex_capability_unsupported`,
`endpoint_alloc_failed`, `server_spawn_failed`, `readiness_timeout`,
`server_died_before_ready`, `endpoint_ownership_unverified`, `auth_setup_failed`,
`frontend_spawn_failed`, `persistence_failed`, `internal_error`.

## tmux dogfood (real codex 0.144.1, sanitized; NO credential values)

Driver: `dev_codex_app_server_dogfood.exe` run in tmux session `t002dog`
(200x50); `codex --remote` frontend inherited the pane tty.

```
BEFORE:  app-server procs = 0 ; remote procs = 0
RUNNING: state=running endpoint=ws://127.0.0.1:44119
         server_pid=1308526 frontend_pid=1312560  (both ALIVE)
         token_env=C2C_CODEX_REMOTE_TOKEN_<unitid>  sha256=<REDACTED>
persisted codex-app-server.json: state=running, endpoint {ws,127.0.0.1,44119},
         token_env_var=<name>, token_sha256=<REDACTED>, server_pid, frontend_pid
         — NO raw token field present.
SIMULATE frontend exit: kill -TERM <frontend_pid>
AFTER:   log "frontend exited -> server stopped; state=offline"
         server alive after: no ; server ps stat: <gone>  (no zombie)
CLEANUP: app-server procs = 0 ; remote procs = 0  (no force-kill warnings)
```

Proves: frontend exit ALWAYS reaps the app-server (no orphan, no zombie); the
persisted state carries only non-secret identity; before/after PID counts show
zero leaked processes.

## Verification (return codes)

| command | rc |
|---|---|
| `test_c2c_codex_app_server.exe` (gate off — 27 tests) | 0 |
| `C2C_CODEX_APPSERVER_LIVE=1 ...exe` (live auth boundary + real_verify_owner) | 0 |
| `just build` | 0 |
| `./scripts/c2c_tmux.py list` | 0 |
| tmux dogfood (server+frontend, reap-proof) | 0 (no leaks) |
| `just check` | 1 — **sole failure PRE-EXISTING + unrelated**: the `git diff --exit-code -- .collab/skills .opencode/skills .codex/skills` step reports Grok/Pi skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` (present vs `origin/master` too; T001 receipt noted the identical drift). Every OTHER step passes independently: `git diff --check` 0, `sync-skills-check` OK, `codegen-alias-words-check` 0, full `dune build` 0, `check-broker-log-catalog.sh` 0, `check-connect-commands.py` 0 (40 cmds). |

`just check` does not execute the alcotest suite (compile-only drift guard); the
suite was run directly (22/22 + gated live) — all green.

## Ownership boundaries for later tasks (also in the `.mli`)

- **T006** owns public grammar (`start`/`codex`/`new`/`resume`), alias
  generation/override, generated-name UX, `--yolo`, flag forwarding. It calls
  `start`/`supervise_step`/`stop`, reads `persisted`, and fills `thread_id`
  (left `None` here). It must NOT re-implement spawning/auth.
- **T003** owns passive `thread/inject_items` ingress over the authed control
  channel (persist-first to the broker inbox; never `turn/*`). This module opens
  no control JSON-RPC session and delivers nothing.
- **T007** owns policy-driven `turn/start`. This module never starts a turn.

## Review round 1 — codex (ccc @cx-reviewer, gpt-5.6-terra xhigh) → FAIL → fixed

The first codex review returned FAIL with legitimate findings for a security
primitive; all were addressed (new commit, not amend):

1. **BLOCKER — port-allocation TOCTOU / token exfil.** Bind-port-0-then-respawn
   left a window for a same-UID adversary to race-bind the loopback port and
   capture the frontend's bearer token. Probed unix-socket transport as an
   alternative (atomic ownership) but codex does NOT cleanly enforce `--ws-auth`
   on unix (authed connect also failed → unproven boundary, which T001 forbids
   shipping). Fix: `real_verify_owner` (/proc process-group listener-ownership
   check) gates frontend spawn — race-free because it runs after our server holds
   the bound socket. See "Startup-race hardening" above.
2. **MAJOR — PID-reuse in stale recovery.** `classify_persisted` now verifies a
   recorded pid's `/proc/<pid>/cmdline` matches our codex-on-this-endpoint before
   signaling (test `recovery / pid-reuse safe`).
3. **MAJOR — restart orphaned prior unit.** `start` now loads + recovers prior
   persisted state (reaping the old pair) and takes an instance flock before
   allocating/overwriting.
4. **MAJOR — process-group teardown.** The headless server is spawned as a
   session leader (setsid) and reaped via killpg (server + helper children); the
   frontend keeps its controlling tty (reaped by pid). Added `supervise_until_exit`
   (installs SIGTERM/SIGINT→stop, owns the poll loop) so the primitive is
   self-contained; dogfood uses it.
5. **MAJOR — discarded persistence errors.** The Running-state mapping persist is
   now mandatory; on failure the unit is torn down + reaped and `persistence_failed`
   returned (test `lifecycle-failures / persistence failure tears down`).
6. **MAJOR — capability gate too weak.** Added a `--help`-based capability probe
   for the exact required flags, before alloc/spawn (`codex_capability_unsupported`).
7. **MAJOR — test rigor.** Added ownership/capability/persistence/pid-reuse/
   supervise-loop tests; server-died-before-ready now asserts reaping. (22 → 27
   fixture tests; live test now also asserts `real_verify_owner`.)
8. **MINOR — fd leak.** `real_spawn_server` wraps its devnull/log fds in
   `Fun.protect`.

Residual (documented, not a defect of this slice): same-UID is not an OS
boundary (T001) — a determined same-UID attacker can already read the frontend's
`/proc/<pid>/environ`. The capability token + /proc ownership gate are
defense-in-depth within the same-UID trust domain, which is exactly T001's model.
