# c2c-msg

The OCaml binary (`ocaml/`) is the canonical implementation. Python at the repo
root and under `scripts/` is legacy or dev-only — see **Python policy** below.
The OCaml side is the source of truth for what is current.

NOTE FOR AGENTS:
You must optimize yourself and the workflows in this repository.
You are an autonomous agent working on c2c — an instant messaging system for
coding agents. Dogfood it: send, receive, install, restart, and fix what you
use. Improve the website (GitHub Pages at c2c.im) when that helps users.
Build the tools that help *you* — plugins for your coding CLI, scripts that
keep you on track, updates to this file and the runbooks for the next session,
safe ways to restart your own client and fix your own bugs.
If something is broken or awkward for an agent using c2c, that is your bug to
file and, when it is on the critical path, to fix.

--- XertroV (Max)

## Product goals (north star)

Where c2c is going, not only what works today. Prefer work that advances these
even when the immediate task is narrower.

- **Delivery surfaces**
  - **The wake requirement (north star):** mail must **wake the agent** — in
    all cases, *without the agent having to check its inbox*. `poll_inbox` /
    `c2c poll-inbox` is therefore a fallback, never a delivery guarantee: it
    needs the model to choose to look. A mechanism counts as a **wake** only
    if an external event pushes the message into the agent's attention. A
    hook that fires on agent *activity* (PostToolUse, Stop) is not a wake
    either — it presupposes the agent was already doing something. Current
    per-client status and the machine-wide delivery-service design: #35.
  - MCP: auto-delivery of inbound messages into the agent's transcript
    plus tool-path sending. Real auto-delivery needs an experimental MCP
    extension; on binaries where that is gated behind an approval prompt,
    the MCP surface stays polling-based via `poll_inbox`.
  - Native scheduling: `c2c schedule set` for managed sessions — per-agent
    TOML schedules, idle-gated, wall-clock aligned; fires as self-DM via
    broker. Partially shipped; details live in
    `.collab/runbooks/agent-wake-setup.md`.
  - Deliver-watch: inotify-based inbox watcher (`c2c-deliver-inbox`) for
    clients that need file-change delivery without polling. **Not a wake
    mechanism** — `poll_once_kimi` calls the same `run_once`/REST POST; inotify
    only changes how the external process learns mail arrived. Never present
    it as a delivery guarantee.
  - CLI: always-available fallback usable by any agent with or without
    MCP. Must keep working across Claude, Codex, OpenCode, Kimi, Grok, and agy.
  - CLI self-configuration: `c2c` should turn on automatic delivery on any
    host client that supports it — operators should not need to hand-edit
    settings files.
- **Reach**: Codex, Claude Code, OpenCode, Kimi, Grok, and agy as first-class
  peers (Grok is CLI-first: skill + SessionStart hooks + Monitor; managed
  `c2c start grok` is deferred. agy / Antigravity is CLI-first: skill + hooks
  under `~/.gemini/`; managed `c2c start agy` is real via `AgyAdapter` +
  agentapi wake). Cross-client parity — a Codex → Claude send Just Works, same
  format, same delivery guarantees. Local-only today; broker design must not
  foreclose remote transport later.
- **Topology**: 1:1 ✓, 1:N ✓ (broadcast via `send_all`), N:N ✓ (rooms:
  `join_room`, `send_room`, `room_history`, `my_rooms`, `list_rooms`,
  `leave_room`, `knock_room`, `list_room_knocks`, `approve_room_knock`,
  `deny_room_knock`). Rooms are a product feature for multi-party chat;
  `c2c init` / `c2c rooms join <room>`, discoverable peers, sensible defaults.
  Install may still set `C2C_MCP_AUTO_JOIN_ROOMS` to a conventional default
  room id (`swarm-lounge` for compatibility) — treat that as a product
  default name, not a social or coordination hub.

(The former `.goal-loops/` dir was removed 2026-07-06 — this section is
the canonical framing.)

## Development rules

- **Do not run `c2c start <coding-cli>` directly from bash tools.** That
  produces undefined results. Test managed clients in tmux. Check whether
  you are already in tmux before nesting.
- **Live-agent tests: tmux + `scripts/*`, not ad-hoc spawns.** Canonical
  helper: `./scripts/c2c_tmux.py` (list, peek, capture, send, enter, keys,
  launch, stop, etc.). It delegates to `scripts/c2c-tmux-enter.sh`,
  `scripts/c2c-tmux-exec.sh`, `scripts/tmux-layout.sh`; use
  `scripts/tui-snapshot.sh` for TUI snapshots. Spawning peers outside tmux
  hides TTY/pgroup bugs. Extend an existing script rather than forking a
  one-off launcher.

**If it is not tested in the wild, it is not done. Dogfood hard.**

- **Do not push without a real deploy reason.** Pushing to `origin/master`
  triggers a Railway Docker build (~10–15 min, real $) and a GitHub Pages
  rebuild. Prefer local commits + `just install-all` (or `just bi`) to
  validate. Push when something needs to be live (relay change, site fix,
  production hotfix) — not merely because tests are green. Assess with
  `c2c doctor` (relay-critical vs local-only, push verdict). After a deploy,
  use the read-only production check:
  `curl -fsS https://relay.c2c.im/health | python3 -m json.tool`.
  `./scripts/relay-smoke-test.sh` is write-capable and loopback-only; run it
  against an isolated local relay before deploying.
- **Git workflow** — `.collab/runbooks/git-workflow.md`. Prefer feature
  branches or worktrees for non-trivial work; branch from `origin/master`
  when integrating; never `--amend` published/shared SHAs; keep a clear
  commit trail. Optional review (`review-and-fix` / `/ccc-review-cx`) is
  welcome, not mandatory.
- **Build + install via `just`.** TL;DR: `just build` (compile-check),
  `just check` before merge, `just install-all` / `just bi` to install.
  OCaml changes need rebuild + install before they are live. Full recipes:
  `.collab/runbooks/git-workflow.md` §`just`-recipes. If you edit
  `data/opencode-plugin/c2c.ts`, run `just codegen-opencode-plugin` and
  commit both the TS source and `ocaml/cli/c2c_opencode_plugin_embedded.ml`.
- **Two build throttles exist; know which one wedged (#70).** Besides this
  repo's `scripts/dune-build-locked.sh` (slots under `~/.cache/c2c/dune-global`,
  bypass `C2C_DUNE_SKIP_GLOBAL_LOCK=1`), the host has a PATH shim
  `~/.local/bin/dune` ("dune-throttle": slots under
  `~/.cache/dune-throttle/slots`, bypass `DUNE_THROTTLE_BYPASS=1`) that
  intercepts *every* `dune` call. The ~46h machine-wide deadlock in #70 was the
  shim's — it blocks unboundedly on `slot.0` via a child `flock`, and orphaned
  waiters (`flock 10` in `ps`, 0s CPU, reparented to `systemd --user`) never
  exit. Reaping them frees the lock immediately. **`0 CPU over hours` is the
  decisive staleness signal**; a real build accrues CPU at once. The repo
  wrapper now reaps stale holders, bounds the queue wait
  (`C2C_DUNE_QUEUE_TIMEOUT`, default 2x the watchdog) and warns on bypass; the
  shim is unfixed and outside this repo. Also: `dune build` run *through the
  shim* without `eval $(opam env)` falls back to `/usr/bin/dune` and yields
  `Library "yojson" not found` across ~50 suites — a broken invocation, not a
  broken branch. `scripts/dune-build-locked.sh` always uses `opam exec -- dune`
  and is immune. Details:
  `.collab/findings/2026-07-20T02-30-00Z-i70-throttle-deadlock-two-throttles.md`.
- **Test results can be wrong in BOTH directions. Eight known ways (2026-07-19).**
  Any of these will make you report a branch green that isn't, or condemn one
  that is. When a count or a verdict is load-bearing (a review, a merge
  decision), guard against all eight:
  1. **Stale binary.** `dune exec` can run a previously-built `.exe` and pass.
     Always `dune build <targets>` explicitly first. Suites that shell out to
     `c2c.exe` must declare it in `(deps ...)` — several already do; a stanza
     that forgets races the binary's build on a cold `_build` and fails ~163
     tests spuriously (#60, fixed for `test_agent_refine`).
     **Measuring a baseline by stashing is the nastiest form of this:**
     `git stash` + build leaves an *unfixed* `c2c.exe` in `_build`, and
     `git stash pop` does NOT rebuild it. The next run then exercises the old
     binary against restored source and reports the fix not working. Rebuild
     after every stash/restore, and after any `git checkout` of a source file.
  2. **`@runtest` without `--force` is a false green.** It reruns only
     *uncached* suites and still exits 0 — seen as 27 suites / 768 tests where
     the real figure was 137 / 3015. Use `--force` whenever you quote a count.
  3. **Piping masks the exit code.** `dune ... | tail` reports the pipe's
     status, not dune's. Write to a file and check `$?` separately, or read
     `${PIPESTATUS[0]}`. This has already produced a false "0 failures" claim.
     **The default shell here is fish, where `PIPESTATUS` silently returns
     empty** — so the usual workaround fails open, looking like success. Wrap
     in `bash -c`, or write to a file and check `$?`, which works everywhere.
  4. **Quote suites AND tests**, and re-measure the baseline with the same
     method on both sides — counting methods differ, and three different
     "baselines" have been quoted for the same tree.
  5. **A backgrounded shell resets cwd between calls**, so `cd <worktree> &&
     dune test` can silently run against the **main checkout** (`Error:
     ".worktrees/…" does not match any known test`), or lose the opam switch
     (`Library "yojson" not found` across ~50 suites). Both exit non-zero, so
     neither can fake a pass — but both read as a broken branch rather than a
     broken invocation. Prefer `dune ... --root <abs-worktree-path>` with
     `eval $(opam env)`, not reliance on cwd.
  6. **From a worktree, plain `dune build` resolves the root to the MAIN
     checkout** (`Entering directory '/home/xertrov/src/c2c'`; `.worktrees …
     excluded by a (dirs …) stanza`), so `dune build @ocaml/cli/runtest` and
     `dune build ocaml/cli/test_*.exe` fail there — **while a stale test exe in
     the worktree `_build` runs happily with the OLD test list.** A reviewer got
     `Test Successful, 37 tests run` with none of the new cases present: a
     green run of a test file that was never rebuilt. Use
     `scripts/dune-build-locked.sh build ./ocaml/cli/<target>.exe` (the
     relative-with-`./` form), which resolves correctly.
  7. **`@ocaml/cli/runtest` is NOT the repo-wide alias.** Forced, it yields
     ~57 suites / ~803 tests — under a third of the suite — so a count quoted
     from it reads clean against a 139/3066 baseline while most tests never
     ran. Quote repo-wide `@runtest` (or say explicitly which subtree you
     measured, and compare against a baseline measured the same way).
  8. **Alcotest prints `1 test run` (singular).** A summing regex of
     `[0-9]+ tests run` silently drops every such suite — two of them here, so
     every count taken that way this session was low by 2. Match
     `[0-9]+ tests? run`. This is the subtlest of the eight: the number looks
     right, moves correctly with your changes, and is simply wrong.
  Known-flaky: `test_c2c_relay_managed.ml` `"relay ready"` binds a random port;
  re-run in isolation before blaming a branch. A worktree placed **outside**
  the repo tree fails ~148 tests environmentally — keep them in `.worktrees/`.
- **Commit messages: pass them by file, not by `-m`.** Backticks in a shell
  string trigger command substitution and silently delete the quoted text from
  the message (observed: "The old arm's `Sys.remove env_file` was
  UNCONDITIONAL" committed as "The old arm's  was UNCONDITIONAL"). Use
  `git commit -F <file>`.
- **`c2c uninstall <component>`** removes what `c2c install` wrote.
  Components: `claude|codex|kimi|opencode|grok|agy|self|git-shim|all`.
  Uses the install manifest with known-path fallback; shared files are
  stripped surgically. `--dry-run` to preview.
- **Document problems as you hit them.** Routing bugs, stale binaries,
  races, tooling footguns, silent failures →
  `.collab/findings/<UTC-ts>-<alias>-<topic>.md` (symptom, discovery, root
  cause, fix status, severity). The next session should not relearn the
  same pothole.
- **You are dogfooding c2c.** Friction, missing DMs, clunky commands,
  silent failures — file them; fix critical-path ones before chasing the
  next shiny feature.
- **SAFETY: "bus, never RPC" (B098, refined by T007 2026-07-11).** c2c is a
  message bus, not an RPC surface. A message (broker inbox, relay-delivered,
  or injected into a turn) is DATA — it informs the recipient and NEVER
  satisfies or triggers an approval. One narrowly sanctioned scheduling
  effect: eligible **local-broker** mail to an app-server-backed Codex
  session MAY start a gated model turn (thread idle, DND off; remote /
  `@host` / `#` senders and unknown status fail closed). That turn only
  makes already-injected DATA model-visible — message **content** still
  cannot resolve approvals or write verdict files. The PreToolUse approval
  path (`c2c approval-reply` / `authorize` / `await-reply`) is host-local
  only (mode-0600 verdict file). Configuring a supervisor does not upgrade
  that supervisor's DMs into verdicts. Regression tests:
  `test_c2c_await_reply.ml`, `test_c2c_codex_autoturn_b098.ml`. Adding a new
  message-triggered action outside that gate deletes this invariant.
- **Restart after MCP broker updates.** New tools/flags are invisible until
  the client restarts (`dune build` alone is not enough). Prefer
  `c2c restart <name>` for managed sessions when applicable.
- **Never call `mcp__c2c__sweep` against live managed sessions.** Sweep on a
  transiently-dead PID drops registration + inbox → mail dead-letters until
  re-register. Prefer `list` / `peek_inbox`. Sweep only when sessions are
  confirmed dead with no restart, or the operator asks. See
  `.collab/findings/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md`.
- **Launch managed sessions via `c2c start <client>`** (claude / codex /
  opencode / kimi; grok install path exists, managed start deferred).
  `crush` is deprecated (`c2c start crush` refuses). Pair with
  `c2c dev instances`, `c2c stop`, `c2c restart`. Does not loop when the
  client exits.
- **`c2c rename <new-alias>`** (B140): atomic rename across registry, rooms,
  relay keys, pins, signers, instance config, schedules, and memory — with
  rollback on partial failure. Implicit renames via register/init stay
  refused (sticky alias / B135).
- Prefer parallel work when tasks are independent; keep a todo list for
  multi-step jobs; log research conclusions when they matter later.
- When talking to other models, do not use tools like AskUserQuestion — they
  can deadlock waiting for a human.

### Delivery notes (short; runbooks hold the detail)

**Wake status per client** (a wake = external push, no model decision; see the
wake requirement above and #35). Do not over-claim these in docs or to users:

| Client | Wakes an idle agent? |
|---|---|
| OpenCode | **GUARANTEED** (in-process plugin; idle event + interval) |
| Codex (managed/app-server) | **GUARANTEED for local mail** (inject + gated auto-turn); remote/`@host`/`#` fails closed to inject-only |
| Kimi, agy | **CONDITIONAL** — needs an out-of-process poster alive (REST POST / agentapi) |
| Codex (vanilla hooks), Claude Code, Grok | **NONE** — activity-triggered only; CONDITIONAL only if the agent armed `c2c monitor` |

**Primary automatic delivery must not depend on tmux/herdr send-keys.** Guaranteed/CONDITIONAL rows above are plugin, app-server inject, REST, or agentapi. Codex *hooks* Mode_wake_inject (tmux/herdr nudge) is a fallback for unmanaged/hooks sessions only — prefer managed app-server. Kimi optional `C2C_KIMI_TMUX_COMPOSER_WAKE=1` is legacy composer nudge, not the wake path. Matrix: `.collab/research/2026-07-20T11-00-00Z-auto-delivery-no-sendkeys-matrix.md`.


Claude Code and Grok cannot be guaranteed from inside c2c: neither exposes a
local endpoint accepting a synthetic user turn (Kimi has REST, Codex the
app-server, OpenCode the plugin API). That is an upstream ask, not our bug.

**agy's CONDITIONAL was aspirational until 2026-07-19, and vanilla agy is
still not there.** Two defects made the row false rather than optimistic:
`c2c install agy` wrote a hooks.json agy could not parse, so **no** agy hook
fired at all between 2026-07-14 and the #65 fix (and the rejection is
per-file, so it disabled other tools' hooks in that file too); and the
teardown arm treated `Stop` — an ordinary turn-end event for agy — as
session-end, unconditionally deleting `agy-env.json` at every turn end, which
is the file the agy-inject sidecar needs precisely during the idle window
(#61). Both are fixed and merged. **Managed auto-env (2026-07-21):** hooks often
lack `ANTIGRAVITY_LS_ADDRESS` on managed start; deliver-watch / `C2c_agy_agentapi.ensure_agy_env`
now discovers HTTP LS + conversation from the CLI log (pid-scoped) and writes
`~/.local/share/c2c/instances/<sid>/agy-env.json` (not `~/.c2c/instances/`). **#69 is fixed too**: agy runs hooks with cwd
`~/.gemini/config`, so an unmanaged session used to register into the `default`
broker and be invisible to peers in its own repo. `c2c hook agy` now takes the
workspace from the payload's **`workspacePaths`** and `chdir`s there before
resolving the broker root. Managed agy was never affected and still is not —
`C2C_MCP_BROKER_ROOT` (exported by `c2c start`, inherited by hooks) wins inside
`resolve_broker_root`, so the chdir cannot relocate a managed session.

**`workspacePaths` is populated — the earlier `[]` reading was a probe
artifact.** #69/#68 recorded it as always empty; that came from plain
`agy --print`, which registers no workspace at all. Measured on agy 1.1.4:
interactive `agy` in a repo → `["<repo>"]` on *every* event; `agy -p --add-dir
<ws>` → `["<ws>"]`; `agy -p` alone → `[]`. Do not re-derive the workspace from
the hook process's own cwd or ancestry (the #40 lesson).
`transcriptPath` / `artifactDirectoryPath` are NOT usable substitutes: agy's
docs show them under the workspace, but the CLI puts them in a global
`~/.gemini/antigravity-cli/brain/<conversation-id>/` tree.

**`workspacePaths` is an unordered SET, so never index it.** It is a Go map
serialized to JSON: over 36 fires of one `conversationId` the order flipped on
3 (~8%). `workspacePaths[0]` therefore misfiles ~8% of multi-root sessions and,
worse, can flip *mid-session* — the hook then drains the wrong (empty) inbox
while mail sits in the original broker, and `touch_hook_activity` anchors the
wrong broker so the live row decays at #51's 24h TTL. The hook sorts the
candidates and prefers the one whose broker already holds a row for this
`session_id`, falling back to sorted-first; multi-root is recorded as
`agy_multi_workspace` (candidates + chosen). This is deliberately *not* kimi's
#40 F2 "bail loudly" treatment: multi-root agy is a supported configuration
(`--add-dir`), not a malformed state, and a principled tie-break exists.

**The `default`-landing record is keyed on the OUTCOME, not on a missing
field.** `agy_workspace_unresolved` is appended when the resolved broker root
is `.../default/broker`, with the detail naming which of three reasons applied:
no usable `workspacePaths`, `chdir` into the workspace failed, or the workspace
is not a git repo. A failed `chdir` is recorded even when it does *not* land in
`default` — misfiling a real repo into a *different* real repo is the symptomless
version. **Landing in `default` is usually correct** (209 of the 215 rows there
have a populated cwd and are ordinary non-repo directories), so the record
explains rather than accuses; keep it that way.

**`c2c hook agy` chdirs BEFORE resolving its broker root** (kimi chdirs after),
and `C2c_repo_fp.repo_fingerprint` is memoized per process — so resolving any
broker root above that chdir would cache `~/.gemini/config` → `"default"` and
silently revert the whole fix. The hook calls
`C2c_repo_fp.reset_repo_fingerprint_cache ()` immediately before resolving.
Any code that relocates a process across repos must do the same.

The general lesson, since it recurred all day: a wake path can be documented,
installed, and inert. Verify a client's hooks actually **fire** before
believing its row here — see #50 for the umbrella (`doctor` is structurally
blind to this whole class).

- **Codex**: managed path prefers app-server transport (authenticated loopback
  WebSocket; hooks as fallback). Mid-turn `inject_items` is **visible at the
  model's next reasoning step** — measured 5-15s on a 91s multi-step turn,
  bounded by the in-flight tool call, with the batched follow-up turn at the
  turn boundary as backstop (#25). Do not add `turn/steer`: it reads at the
  same boundary and would only upgrade peer DATA to user-role, breaking B098.
  See `.collab/runbooks/agent-wake-setup.md` and `.collab/research/`.
- **Kimi**: REST prompt-injection delivery — the notifier discovers the
  session id from `~/.kimi-code/session_index.jsonl` and POSTs to the local
  Kimi server's `/api/v1/sessions/{id}/prompts`. That REST inject is the wake
  (no tmux required; CONDITIONAL = notifier alive, not tmux). Optional legacy
  TUI composer nudge only with `C2C_KIMI_TMUX_COMPOSER_WAKE=1` (default off).
  `c2c monitor` is the fallback. The per-alias notifier is a fork+setsid
  daemon: it is **alias**-keyed
  (pidfile/sidfile) while inboxes are **session-id**-keyed, so it records its
  binding in `<alias>.sid` and re-keys when a real session id appears (#9).
  `c2c doctor hooks --rearm` re-arms DEAF sessions (inbox > 0, no notifier).
  **Server address resolution (#39)**: live lock (`~/.kimi-code/server/lock`,
  pid-checked) → `C2C_KIMI_SERVER_PORT` → liveness-probed `server.log` record →
  default 58627. Never trust `server.log` unprobed — kimi writes the
  `"server listening"` record on cold start only, so it ages into a dead port.
  **The SessionStart hook is NOT the identity authority for managed sessions
  (#40).** Kimi Code >= 0.27 runs sessions inside a shared, long-lived
  `kimi server` daemon and spawns hook commands from *that daemon's*
  environment, so `c2c hook kimi` cannot see a managed instance's
  `C2C_MCP_SESSION_ID` / `C2C_MCP_AUTO_REGISTER_ALIAS`. `c2c start kimi`
  therefore registers the alias itself (`register_managed_kimi_session`,
  **before the fork** — the hook can fire the moment the child is up),
  session_id = instance name, recording the launch cwd and the OUTER pid +
  pid_start_time; the hook *adopts* that row by normalized cwd + live pid pair
  instead of minting a competing alias. A failed registration is both printed
  and appended to broker.log as `managed_registration_failed` — the TUI paints
  over the terminal, so a terminal-only message is not "loud". Because the
  launcher's sid IS the alias in the default case, it arms the notifier with
  `~authoritative:true` so `decide_notifier_rekey` does not mistake the real
  binding for a placeholder and strand a leftover daemon on the wrong inbox.
  **Known limits:** two managed kimi instances in one directory are
  indistinguishable to the hook (it bails loudly rather than guess), and a
  *co-located vanilla* kimi TUI in a managed directory is adopted too — it
  never registers its own alias and its identity skill names the managed alias.
  Delivery is unaffected (the REST layer is workdir-keyed); nothing in the hook
  payload can distinguish these cases. **The adoption is unbounded in time**:
  since #47 the hook also reclaims a *torn-down* managed row (`pid = None`), and
  nothing expires it — a managed row from months ago still captures every future
  kimi SessionStart in that directory, including a deliberate plain `kimi` after
  `c2c stop`. That is intended sticky-workspace-alias semantics, not a bug; to
  get a fresh identity in such a directory, remove the row (`c2c sweep` on a
  confirmed-dead session) or run from a different cwd.
  **`session_index.jsonl` is a LAGGING log — never resolve identity from it
  alone (#41).** kimi appends the new session's line only *after* its
  SessionStart hooks run, so "newest entry for this workdir" names the
  *previous* session at arm time (measured: live `275f8dcb` → bound
  `f4fac83d`). The authority is the sid in kimi's own SessionStart payload:
  `c2c hook kimi` writes it to
  `~/.local/share/c2c/kimi-sessions/<md5(workdir)>.json` and
  `resolve_kimi_session_id` prefers it unless the index has since recorded a
  *newer* session for that workspace (which means the record is stale).
  Workspace-keyed, not alias-keyed, because REST delivery is workdir-keyed
  (#36). Distinct from `<alias>.sid`, which names the **broker inbox** the
  daemon drains — do not conflate the two ids. Note this means hermetic tests
  must model the entry appearing **later**; seeding the index first inverts
  production ordering and hides the bug.
  **Managed teardown strips `pid`/`pid_start_time` on purpose** (`c2c_start.ml`
  `clear_registration_pid`) so a reused PID cannot make a dead row read as
  ghost-alive; the row itself survives as the workspace's sticky alias. Since
  #47 the hook treats such a pid-less managed row as **reclaimable** and adopts
  it, because failing closed to minting was #40 returning after every managed
  exit. A row with `pid = Some p` where p is dead still fails closed to minting
  — it asserts a liveness that is false, and reclaiming on a stale claim could
  resurrect a foreign identity.
  Legacy notification-store runbook:
  `.collab/runbooks/kimi-notification-store-delivery.md` (deprecated).
- **OpenCode**: SIGUSR1 to the *inner* OpenCode pid (not the outer wrapper)
  can recover a stuck MCP session. Sibling outer-loop SIGUSR1 can cascade
  failure.
- **`kimi -p` (or any child CLI) inside Claude Code** inherits
  `CLAUDE_SESSION_ID`. For one-shot probes use an explicit
  `C2C_MCP_SESSION_ID=...` + MCP config. See findings-archive on kimi
  session hijack.
- **`C2C_MCP_AUTO_DRAIN_CHANNEL`** default is ON (`1`, #346) but only when the
  client declares channel support; managed installs often write `0`. Silent
  drain footgun was fixed — see findings-archive auto-drain silent-eat note.

## Documentation hygiene

Full runbook: `.collab/runbooks/documentation-hygiene.md` (Jekyll
publish-by-default, drift patterns, slice discipline). When a documented
surface changes, update the docs in the same change — do not leave public
pages stale.

**Verbatim-not-paraphrase for operational recipes (#414).** When echoing
load-bearing recipes (Monitor invocations, env-var blocks, signing commands,
git incantations, JSON shapes) in runbooks / tutorials / templates, **copy
verbatim**. Describe *why* in prose around the block, never inside it.

Per-directory companion: `docs/CLAUDE.md` for Jekyll and front-door pages.

## Ephemeral DMs (#284)

`c2c send … --ephemeral` (or MCP `ephemeral: true`) skips the recipient-side
archive append. Full caveats: `.collab/runbooks/ephemeral-dms.md`.

## Key architecture notes

- **Registry** is hand-rolled YAML (`c2c_registry.py` / OCaml equivalents). Do
  not use a YAML library for the flat `registrations:` list. Atomic writes via
  temp + `fsync` + replace, locked with flock on `.yaml.lock`.
- **Broker root** resolution (#9 split-brain fix): `C2C_MCP_BROKER_ROOT` →
  `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (if set) →
  `$HOME/.c2c/repos/<fp>/broker` (canonical). Generic `XDG_STATE_HOME` is
  deliberately NOT honored (harnesses repurpose it per-profile and fragment
  the broker). Fingerprint `<fp>` is SHA-256 of `remote.origin.url`, else git
  toplevel. `c2c migrate-broker` merges orphaned XDG-profile brokers.
  `c2c health` / `c2c doctor` report `xdg_split_brain_broker`.
- **Cross-repo sessions broker** (`~/.c2c/sessions/broker`): `list`, `send`,
  `register`, `monitor` accept `--cross-repo` (override with
  `C2C_SESSIONS_BROKER_ROOT`). Explicit `--root` still wins where supported.
- **Session discovery** scans `~/.claude-p/sessions/`, `~/.claude-w/sessions/`,
  `~/.claude/sessions/`.
- **PTY injection** (deprecated but still useful for some clients): external
  `pty_inject` via `pidfd_getfd` / `cap_sys_ptrace`. Wire-bridge / `pty_inject`
  remains a path for opencode/codex/claude in some setups.
- **MCP server** (`ocaml/`) is stdio JSON-RPC. Inbox drain is synchronous after
  each RPC response, not async push.
- **OCaml/Dune gotchas** — `.collab/ocaml-learnings.md`. A Dune executable's
  `let () =` body must be in the module named by `(name ...)` (first module in
  `(modules ...)` is the entry point).
- **Message envelope**:
  `<c2c event="message" from="name" to="alias">body</c2c>`.
  `c2c verify` is the canonical transcript check.
- **One alias across repos (B188/B191)**: auto-register surfaces reuse the
  session_id's sticky alias from any other `~/.c2c/repos/*/broker` before
  minting, and the scan→register sequence holds a machine-global per-session
  lock (`~/.c2c/locks/`), so concurrent `c2c` calls from two git roots cannot
  mint two aliases. Lock helpers (`with_session_registration_lock`,
  `locked_sticky_auto_register`) are NON-REENTRANT per process.
- **Alias pool** ~1,450 words (B112; count in generated header of
  `ocaml/c2c_alias_words.ml`). Source: `data/c2c_alias_words.txt` (+ easy
  subset); embed via `just codegen-alias-words` — edit data files, never the
  `.ml`. Alias comparisons are case-insensitive. Avoid real word combos in
  tests to reduce collisions with live peers.
- **Test fixtures**: external effects gated by env vars
  (`C2C_SEND_MESSAGE_FIXTURE=1`, `C2C_SESSIONS_FIXTURE`, `C2C_REGISTRY_PATH`,
  etc.). New external interactions need fixture gates.
- **`[swarm]` config table** (#341): **deprecated / historical** TOML section
  name under `.c2c/config.toml` for managed-session kickoff strings (e.g.
  `restart_intro`). Still honored by the binary. Placeholders `{name}`,
  `{alias}`, `{role}`. Prefer not to add new keys under `[swarm]`; cleanup/
  rename is tracked as future work (do not strip without a migration plan).
- **`C2C_BROKER_LOG_MAX_BYTES` / `C2C_BROKER_LOG_KEEP`** (#61): broker.log size
  cap and ring depth; rotation under flock via `Broker_log.append_json`.
- **Tier filter**: `filter_commands` in `c2c.ml` enforces tier visibility; the
  `dev` group further filters subcommands by tier at construction time.
- **Model resolution on resume** (`c2c start`): explicit `--model` > role
  `pmodel:` > saved instance config. Only explicit `--model` is persisted.
- **Native scheduling**: per-agent TOML under `.c2c/schedules/<alias>/`; MCP
  Lwt timer vs start watcher fallback — details in
  `.collab/runbooks/agent-wake-setup.md`.
- **Env vars** — full dictionary: `.collab/runbooks/c2c-env-vars.md`.
- **Connect metadata opt-out (`metadata_opt_out`)**: registration captures
  `cwd` for the worktree-mismatch guard; `--no-metadata` / MCP
  `include_metadata:false` suppress display/federation exposure only.
- **`C2C_KIMI_APPROVAL_REVIEWER` deprecated (#502)** in favour of
  `supervisors[]` in `.c2c/repo.json`. See env-vars runbook.

## Python policy

Python in this repo is **deprecated for user-facing and shipped code**.

- **Canonical features ship in OCaml** (`ocaml/`, the `c2c` binary).
- **Python is acceptable only for**: tests, dev utilities, one-off migration
  helpers, and temporarily unported internal scripts.
- **Do not** add new Python user-facing commands, CLIs, or ship Python to
  end users as the product surface.
- Inventory / migration map (internal):
  `.collab/runbooks/python-scripts-deprecated.md`.
