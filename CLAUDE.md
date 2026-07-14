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
  - MCP: auto-delivery of inbound messages into the agent's transcript
    plus tool-path sending. Real auto-delivery needs an experimental MCP
    extension; on binaries where that is gated behind an approval prompt,
    the MCP surface stays polling-based via `poll_inbox`.
  - Native scheduling: `c2c schedule set` for managed sessions — per-agent
    TOML schedules, idle-gated, wall-clock aligned; fires as self-DM via
    broker. Partially shipped; details live in
    `.collab/runbooks/agent-wake-setup.md`.
  - Deliver-watch: inotify-based inbox watcher (`c2c-deliver-inbox`) for
    clients that need file-change delivery without polling.
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
  `c2c doctor` (relay-critical vs local-only, push verdict). After a
  deploy: `./scripts/relay-smoke-test.sh`.
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
- **`c2c uninstall <component>`** removes what `c2c install` wrote.
  Components: `claude|codex|kimi|opencode|grok|agy|self|git-hook|git-shim|all`.
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
  opencode; grok install path exists, managed start deferred). **B146-TEMP:**
  kimi install/start/new temporarily disabled. `crush` is deprecated
  (`c2c start crush` refuses). Pair with `c2c dev instances`, `c2c stop`,
  `c2c restart`. Does not loop when the client exits.
- **`c2c rename <new-alias>`** (B140): atomic rename across registry, rooms,
  relay keys, pins, signers, instance config, schedules, and memory — with
  rollback on partial failure. Implicit renames via register/init stay
  refused (sticky alias / B135).
- Prefer parallel work when tasks are independent; keep a todo list for
  multi-step jobs; log research conclusions when they matter later.
- When talking to other models, do not use tools like AskUserQuestion — they
  can deadlock waiting for a human.

### Delivery notes (short; runbooks hold the detail)

- **Codex**: managed path prefers app-server transport (authenticated loopback
  WebSocket; hooks as fallback). See
  `.collab/runbooks/agent-wake-setup.md` and related research under
  `.collab/research/` for auto-turn / draft-preservation receipts.
- **Kimi** (machinery retained; install/start disabled for release): file-based
  notification-store delivery — `.collab/runbooks/kimi-notification-store-delivery.md`.
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
