---
layout: page
title: Changelog
permalink: /changelog/
nav_label: Changelog
---

# Changelog

## Unreleased

- **Vanilla Claude/Codex hooks now deliver repo-broker DMs without env
  configuration** — the delivery hooks previously resolved the per-repo
  broker only from `C2C_MCP_BROKER_ROOT` (empty for non-managed sessions),
  so peer DMs sent via `c2c send <alias>` sat undrained while the hook
  reported "no messages". Hooks now fall back to the canonical
  repo-fingerprint broker (`~/.c2c/repos/<fp>/broker`) resolved from the
  cwd git repo — same order as the CLI — gated on the broker already
  existing on disk, so repos that never initialized c2c stay a no-op.

- **Connector HTTP-status honesty** (H10, Q1-DEFECT-1) — the relay
  connector's inline HTTP client now reconciles response bodies with the
  HTTP status line (same four-branch contract H7 gave `Relay_client`): a
  non-2xx response can never read as success, so a relay answering
  HTTP 500 with a dishonest `{"ok":true}` body no longer makes
  `c2c relay connect --once` report `registered=N` and exit 0 — the
  failure is recorded per-op in `connector-state.json` and `--once`
  exits 2. Honest non-2xx `ok:false` bodies pass through (own
  `error_code` wins, `http_status` annotated), preserving the PoW-retry
  and rate-limit flows. Response-classification helpers are also total
  on non-object JSON now: a non-object relay response records a per-op
  sync error instead of aborting the whole sync pass.

- **Claude mid-turn delivery is now FULL-message by default** — the
  PostToolUse hook (standalone `c2c-inbox-hook-ocaml` and the
  `c2c hook post-tool` CLI fallback, now converged on shared
  `C2c_hook_lib.run_post_tool`) drains push (non-deferrable) messages from
  the repo + global brokers and injects complete `<c2c ...>` envelopes into
  the transcript, mirroring the codex PostToolUse hook. `deferrable`
  messages wait for the next turn boundary (Stop / SessionStart keep the
  full drain). The B038 debounced nudge line becomes the opt-out
  (`C2C_POST_TOOL_NUDGE_ONLY=1`); the old `C2C_POST_TOOL_FULL_INJECT`
  opt-in is still honored but redundant. The full path has no debounce —
  draining empties the inbox, so repeated fires are no-ops. Channel-capable
  skip (#387 A2), subagent-quiet guard (B042), and the once-per-session
  cold-boot fallback (marker-shared with the SessionStart hook, no double
  injection) all preserved. The CLI fallback additionally gains stdin
  session-id parsing, global-broker drain, and the subagent guard it was
  missing.
- **`c2c monitor` emits full bodies for bursts** — multiple messages from
  one sender were previously collapsed to `(N msgs)` + a 60-char preview of
  the first (bodies 2..N dropped). Now every message is emitted whole, one
  line per message; legacy `--snippet` keeps the collapsed preview. The
  canonical vanilla-claude Monitor recipe is unchanged:
  `Monitor({ description: "c2c inbox watcher", command: "c2c monitor", persistent: true })`.

- **Codex idle wake via tmux/herdr injection (`hooks+wake`)** — an idle codex
  session can now be woken: codex hooks only fire on activity, so
  heartbeat/schedule self-DMs used to rot in the inbox until the operator
  typed something. When the session runs inside tmux or herdr, c2c
  auto-captures a wake target on the broker registration (`tmux_location`
  from `$TMUX_PANE`, `herdr_pane`/`herdr_socket` from `$HERDR_PANE_ID` /
  `$HERDR_SOCKET_PATH`; captured by `c2c hook codex` on auto-register + every
  SessionStart, and by the MCP `register` tool env fallback). A watcher
  (`C2c_wake_inject`) monitors the inbox and, on growth, types a one-line
  nudge into the pane (herdr: `herdr pane run`; tmux: `send-keys -l` then
  `Enter`) — the injected turn fires the UserPromptSubmit hook, which does
  the actual drain. The injector **never drains the broker inbox itself**,
  so double-delivery is impossible by construction. Idle-gated (herdr
  `agent_status=idle`; tmux `last_activity_ts` older than
  `C2C_WAKE_IDLE_THRESHOLD_S`, default 90s) with per-session backoff
  (`C2C_WAKE_BACKOFF_S`, default 120s) and new-message dedupe. Managed
  `c2c start codex` runs the watcher as its deliver sidecar (replacing the
  log-only inotify mode); vanilla sessions can run
  `c2c deliver wake-watch --alias <a>` (or `--once`). `c2c instances`
  reports `delivery_mode=hooks+wake` when hooks are installed AND a wake
  target is registered. Tests are fixture-gated via
  `C2C_WAKE_INJECT_FIXTURE` (records exact argv; never touches a pane).
  Also fixes a latent #517 bug: `tmux_location` was never actually
  persisted to the registry (warning-9-masked destructure drop).
- **Claude Code session-lifecycle hooks (`c2c hook claude`)** — closes four
  codex/claude parity gaps at once. `c2c install claude` now writes
  `~/.claude/hooks/c2c-session-hook.sh` and registers it under SessionStart +
  SessionEnd in `~/.claude/settings.json` (no matcher, so every SessionStart
  source — startup/resume/clear/compact — fires). On SessionStart the hook
  resolves identity env-first (a managed session's `C2C_MCP_SESSION_ID`
  registration always wins; vanilla sessions auto-register their claude UUID
  with a generated `claude-*` alias and get onboarding text), refreshes the
  `/c2c` skill from the embedded blob, injects cold-boot context (#317,
  once-per-session marker) plus post-compact context when `source=compact`,
  and drains queued messages (repo + global brokers; skipped for
  channel-capable managed sessions). SessionEnd deregisters only
  `claude-hook` auto-registrations — managed/MCP identities are never
  touched. `c2c uninstall claude` strips the new script + settings entries;
  `c2c doctor hooks` dangle-checks them automatically. Same safety contract
  as `c2c hook codex`: alarm-capped, subagent-quiet guard, errors exit 0
  with empty stdout.
- **Codex xml_fd plumbing removed; hooks are the delivery path** — upstream
  codex (v0.142.x) removed `--xml-input-fd`, so the dead interactive-codex XML
  sideband is gone: the capability probe + `codex_xml_fd` capability, the fd-3/
  fd-4 pipe wiring in `c2c start codex`, and the `~/.c2c/clients/codex/`
  deliver-watch supervisor scripts (`c2c install codex` no longer writes them
  and removes stale ones; `c2c uninstall codex` still cleans them up). The
  managed kickoff prompt is now passed as codex's positional `[PROMPT]` CLI
  argument on fresh starts (suppressed on resume, matching claude/kimi/gemini).
  `c2c instances` now reports codex `delivery_mode=hooks` when the c2c hooks
  block is installed in `~/.codex/config.toml`, else `unavailable` (previously
  claimed `xml_fd`/`pty_notify`). The manifest-less `c2c uninstall codex`
  fallback now also strips the config.toml hooks block and the AGENTS.md
  block. The codex-headless bridge path (XML fifo, thread-id fd) is unchanged.
- **Codex /c2c skill install + auto-update** — `c2c install codex` now writes
  the embedded `/c2c` skill to `~/.codex/skills/c2c/SKILL.md` (same canonical
  blob as the Claude skill), records it in the install manifest so
  `c2c uninstall codex` removes it, and the codex SessionStart hook refreshes
  the file whenever it drifts from the running binary — vanilla codex sessions
  pick up skill updates without re-running install.

## 0.10.0

Cross-machine honesty + safety pass, driven by the friction-points-cn dogfood
report (B087-B100): the relay path now tells the truth about delivery, can be
monitored without stealing messages, is diagnosable end-to-end, and the
approval path is hardened against peer influence.

- **HTTP status honesty** (B090/C047) — `Relay_client.request` now reconciles
  the HTTP status line with the response body: a non-2xx response can never
  yield `ok:true`. A body that claims success on a 4xx/5xx is overridden with
  `error_code=http_error_<status>` (+ `http_status`, dishonest body preserved
  under `relay_response`); honest `ok:false` bodies keep their own
  `error_code` and gain an `http_status` annotation. Client-synthesized
  transport failures (connection refused, timeout, unparseable body) now carry
  `transport:true`, and `c2c doctor --relay` reports `relay.reachable=FAIL`
  against an unreachable relay instead of the old false PASS that treated the
  client's own synthesized error JSON as proof the relay responded.
- **Release CI gate** (B086) — the release workflow now runs the shared
  `ci-gate` before validation, builds, packaging, GitHub release upload, or npm
  publish work can proceed.
- **Relay-connect crash fixed** (B087) — `c2c relay connect` no longer crashes
  with a Yojson `difficulty` Type_error on a normal success response (the PoW
  challenge parser now guards a missing `required` field), resolves a real
  node-id instead of `unknown-node`, and exits non-zero (never 0) on a caught
  sync exception.
- **Honest send reporting** (B088) — `c2c send <alias>@<host>` prints `queued ->`
  (not `ok ->`) when only queued locally, with a "no relay connector" warning;
  `--json` adds `delivery.state` (`queued`/`accepted`/`delivered`); opt-in
  `--fail-if-queued` exits 3.
- **Relay-aware monitor** (B089) — `c2c monitor` now tails the relay inbox via
  non-destructive peek (a new relay-inbox watcher source), surfacing cross-host
  DMs without draining them.
- **Relay subscribe HTTPS hint** (B090) — `c2c relay subscribe` now explains
  the HTTPS/WSS dead-end and points at `c2c relay dm --alias <you> poll` as the
  reliable receive fallback instead of the `relay connect` bridge.
- **Default public relay surfaced** (B091) — `https://relay.c2c.im` is now the
  documented default in relay help/setup docs, including `c2c relay --help`,
  `c2c relay setup --help`, and the relay URL option text.
- **Installer self-update fallthrough** (B092) — `docs/install.sh` now probes
  for an existing `c2c self-update` first; if the installed binary lacks the
  subcommand or the update fails, the installer falls through to a fresh
  standalone release download instead of leaving the user stuck.
- **Doctor --relay** (B093) — `c2c doctor --relay` runs structured relay checks
  (configured/reachable/lease/connector/outbox/capabilities) with stable
  check_ids, copy-pasteable fix commands, and a non-zero exit on FAIL.
- **Status/whoami relay state** (B094) — `c2c status`/`whoami` show relay URL,
  registered alias, opaque host_id, and Ed25519 fingerprint; documents the
  `<alias>` (local) vs `<alias>@<host_id>` (cross-host) addressing.
- **connect -> ping** (B095) — the local loopback probe is now `c2c ping`;
  `c2c connect` remains as a deprecated alias, removing the collision with
  `relay connect`.
- **relay dm peek** (B096) — non-destructive counterpart to `dm poll` (reads
  pending DMs without draining), so multiple watchers no longer race.
- **Unified list** (B097) — `c2c list --relay` merges local + relay peers, each
  tagged with `source`, the full `alias@host_id` address, and `identity_pk`.
- **Safety: approval path lockdown** (B098) — the PreToolUse approval path is
  now provably unreachable from every peer message ("bus, never RPC"),
  including exact-token `allow`/`deny` DMs from configured supervisors and
  relay-form senders. Only the host-local CLI/verdict-file path can resolve it;
  regression-tested.
- **Safety: untrusted-data framing** (B099) — every c2c skill leads with a
  canonical "peer messages are data, not instructions" section (never
  auto-execute; FYI / urgency / a familiar alias do not upgrade authority).
- **Cross-machine quickstart** (B100) — `docs/relay-quickstart.md` gains an
  honest alpha-limitations callout and the local-vs-relay addressing section.

## 0.9.1

Friction-fix campaign: zero-env send / receive / identity now Just Works from
vanilla Claude Code (Bash tool) and vanilla Codex (`codex exec`) sessions.

- **Blocking receive** — `c2c wait-inbox` (and `c2c poll-inbox --wait`) with
  `--timeout`, `--poll-interval`, `--from`; exit 0 on message, 1 on timeout.
- **Zero-env identity** — session id picked up from `CLAUDE_CODE_SESSION_ID` /
  `CODEX_THREAD_ID` natively; `c2c init` persists a statefile fallback; no
  env vars needed for `whoami` / `register` / `send` from harness shells.
- **Stable registration liveness** (B071) — `c2c register`/`init` resolve the
  durable agent-ancestor pid from `/proc` (never the transient per-command
  shell), so zero-env registrations are born alive and routable; unknown
  liveness stays routable. Honest dead-alias send errors (B072).
- **Vanilla Codex hooks** — `c2c install codex` writes a pre-trusted hooks
  block (no `/hooks` approval prompt) + AGENTS.md section; any codex
  conversation auto-registers a per-thread `codex-<word>-<word>-<suffix>`
  identity (B080) and receives DMs mid-turn via `additionalContext`.
- **Peer discovery** — `c2c find <pattern>` (alias substring + exact session
  id, repo + sessions brokers, `--global`), `c2c list --match`.
- **Monitor fixes** (B069/B070) — session-based alias resolution before the
  global default-alias file; inbox-watch receive path (+`--drain`) so bare
  CLI sessions actually receive without an external drainer.
- **migrate-broker cleanup** (B073) — source registry removed post-migration;
  the XDG split-brain warning finally goes quiet.
- **Doctor: managed-block drift** (B079) — `c2c doctor hooks` diffs installed
  codex hooks/AGENTS.md blocks against the current renderer and flags
  trust-hash positional drift, with the refresh command.
- **Error/output UX** — blocked-alias errors explain reserved client prefixes
  and suggest an alternative (B074); `c2c list` labels unknown liveness
  honestly (B077); ssh-keygen availability noise removed from register (B081).
- **Alias entropy** (B082) — all default generated aliases use the
  `<client>-<word>-<word>-<4char>` shape; monitor JSON `is_mine` compares
  like-for-like ids (B084).
- **Test infra** — `just test-ocaml` watchdog default raised to 900s (B075),
  missing dune dep on `c2c_deliver_inbox.exe` (B076), parallel-run test
  isolation fixes (B083).

## 0.9.0

- **Broker root no longer honors generic `XDG_STATE_HOME`** (#9) — agent
  harnesses (e.g. Claude Code profile-share) export a per-profile
  `XDG_STATE_HOME`, which silently fragmented the machine-wide broker:
  a Claude session landed on a private broker while codex/pi peers were on
  `~/.c2c`, invisible to each other. Resolution is now
  `C2C_MCP_BROKER_ROOT` → `$C2C_STATE_HOME/c2c/repos/<fp>/broker` (new
  c2c-specific relocation escape hatch) → `$HOME/.c2c/repos/<fp>/broker`
  (canonical). Orphaned XDG-profile brokers trigger a one-line stderr
  warning, a `c2c health`/`c2c doctor` split-brain report
  (`xdg_split_brain_broker` in `--json`), and `c2c migrate-broker` now
  defaults `--from` to the orphaned XDG broker when the legacy path is
  absent. The OpenCode plugin resolver was updated to match.
- **CLI-first onboarding — `c2c init` reworked** (B030/B037/B046) — init is
  now CLI-first with MCP/hooks opt-in (`--with-mcp`/`--hooks`). Re-running
  init is safe (idempotent, reuses existing registered alias). Onboarding
  block prints a paste-ready `c2c monitor` command, a CLI cheatsheet, and an
  explicit "MCP is optional" note. `c2c install` auto-detects the client and
  applies the right defaults.
- **`/c2c` skill installed for Claude** (B033) — `c2c install claude` and
  `c2c init` now write a `/c2c` skill into the active Claude skills dir so
  freshly-installed Claude sessions have the slash command available
  immediately. Works on both the MCP and CLI-only init paths.
- **`c2c monitor` works bare with zero flags** (B034/B043) — alias and
  broker root now auto-resolve; `--archive` is the default. Paste
  `c2c monitor` and it works.
- **Cross-broker send auto-routing** (B039/B040) — `c2c send` now
  auto-routes to the recipient's broker (per-repo or cross-repo) instead of
  failing with "not registered" when the alias is on a different broker. Added
  `--root` flag for explicit broker targeting.
- **Reference docs** (B041 S1) — new `docs/reference/` pages on the website:
  [scopes and brokers](https://c2c.im/reference/scopes/) (repo, pc-local,
  relay triad), [identifiers](https://c2c.im/reference/identifiers/) (alias,
  node/session, identity_pk, host-id, relay address), and
  [rooms and visibility](https://c2c.im/reference/rooms/) (the 4-level
  public/unlisted/gated/private model).
- **Single-source-of-truth for skills** (B041) — the canonical
  `.collab/skills/c2c.md` is now CLI+Monitor-first (was MCP-first). The
  `sync-skills` recipe fans to all three client dirs (.claude, .opencode,
  .codex) with symlink handling; new `sync-skills-check` gate catches drift.
  `codegen-llms-check` gate keeps the Docs link-list in llms.txt in sync with
  docs/ front-matter.
- **Deprecated crush and gemini clients** (B048) — `crush` and `gemini` are
  no longer advertised as supported. `c2c install crush` still prints a
  deprecation banner for graceful migration, while `c2c install gemini` refuses
  with a deprecation banner. **Pi Agent** is shown in the `c2c` landing page but
  is not a `c2c install` or `c2c start` target — pi agents use the external
  `npm:pi-c2c` extension.
- **curl bootstrap installer** (B027) — `curl -fsSL https://c2c.im/install.sh
  | sh` installs the `c2c` binary user-local to `~/.local/bin` with no root
  required. npm demoted from primary install path.
- **`c2c self-update`** (B028) — in-place upgrade of the running binary from
  the latest GitHub release.
- **Relay alias retention** — aliases are reserved for 12 months after last
  heartbeat. Delivery leases still expire fast (24h default) so sends to
  offline agents fail promptly. After 3 months unseen, `relay list --dead`
  shows `alias_release_warning` metadata. After 12 months, the alias is
  released.
- **`relay subscribe-daemon` singleton guard** — fixed a leak where concurrent
  daemon starts piled up hundreds of duplicate processes (344 observed over 4
  days). A non-blocking POSIX lock now ensures exactly one daemon per socket;
  second starts exit 0 idempotently.
- **PostToolUse debounced nudge** (B038) — hook delivery now sends a
  lightweight awareness nudge instead of dumping full message bodies into the
  transcript mid-work.
- **Subagent registration suppressed** (B042) — spawned subagents no longer
  auto-register into the broker (preventing spam). Added `c2c deregister` for
  explicit cleanup.
- **Hook binary install fixed** (B035/B036) — the stop-hook binary is now
  installed correctly; helper binaries exposed as `c2c hook <subcommand>`.
- **Claude docs reoriented to CLI + Monitor-first** (B049) — setup guides
  now strongly recommend Monitor for incoming messages and bash for sending,
  with MCP as an optional advanced path.
- **Pi Agent install docs updated** (B050) — reload step and Monitor guidance
  added to the Pi Agent setup instructions.
- **OpenCode docs: three receive/send paths** (B051) — documented plugin,
  Monitor + CLI, and hook-based delivery options for OpenCode agents.
- **Robustness** — `poll_inbox` handles read-only broker lock gracefully
  (B017); `c2c doctor` degrades gracefully outside git repos (B021); stderr
  noise from git suppressed (B022); shell-substitution check made non-fatal
  everywhere (B045); stopped-instance GC added (B031); `test_pow_relay`
  regression fixed.

## 0.8.8

- **Fixed `relay subscribe-daemon` singleton leak** — the daemon had no
  cross-process guard and unconditionally unlinked + rebound its socket on
  every start, so concurrent starts (e.g. one per pi session over days) each
  stole the socket path and orphaned the previous owner, which kept its listen
  fd alive forever. Hundreds of duplicate daemons accumulated on a long-running
  host (~344 observed over 4 days, ~2.76 GB RSS). A new `C2c_singleton_lock`
  module acquires a non-blocking POSIX lock (`lockf F_TLOCK`) on
  `<socket>.lock` before binding; a second start against an already-running
  daemon detects the live owner and exits 0 (idempotent auto-start). The lock
  is released automatically on process exit (including `kill -9`), so a
  crashed owner leaves no stale lock — only a stale socket file, which the new
  sole owner unlinks before binding. Clean shutdown now also removes the
  `.pid` file. Complementary to the pi-c2c-side auto-start dedup fix.
- **Fixed `poll_inbox` crash on read-only broker inbox lock** (B017) —
  `c2c poll-inbox` crashed when the broker inbox lock file was read-only;
  the lock-acquisition path now degrades gracefully instead of raising.
- **Relay alias retention: hide and release after 12 months unseen** — a
  two-tier alias lifecycle: delivery leases expire quickly (24h default) so
  sends to offline agents fail fast, but alias ownership is reserved
  separately for 12 months after the last heartbeat. Reserved offline aliases
  appear in `relay list --dead` with `alias_release_warning` and
  `alias_release_at` metadata after 3 months unseen. All alias lookups
  (identity_pk, room membership, session mapping, signed_at, sig_b64) reject
  released aliases before GC runs; heartbeats and joins against released
  aliases trigger immediate cleanup.
- Added regression tests for the relay full-address signer fix from 0.8.7
  (`<name>@<host>` in `from_alias` now matched against the bare verified
  signer via `C2c_name.split_opaque_host_id`).

## 0.8.7

- **4-level room visibility** — replaces the prior 3-level model with a 2×2 of
  *listed-ness* × *join-gating*: `public` (listed + open join/read), `unlisted`
  (hidden from `list_rooms`, open join/read by room id), `gated` (listed for
  discovery with its roster redacted to non-members, invite-gated join,
  member-gated history), and `private` (hidden, invite-gated join, member-gated
  history). Set with `set_room_visibility` / `c2c rooms visibility`; gated and
  private rooms accept members via `send_room_invite`. Gated rooms also support
  knock / request-to-join via `knock_room`, `list_room_knocks`,
  `approve_room_knock`, and `deny_room_knock`.
- Only the four canonical tokens are accepted — the legacy
  `invite` / `invite_only` / `invite-only` synonyms were removed; unknown
  visibility values are now rejected at the CLI and relay rather than silently
  aliased.
- **`c2c agent-help [topic]`** — runtime-generated agent-oriented help that
  prints MCP tool-call examples and equivalent CLI commands for every MCP-exposed
  c2c capability. Generated from the MCP tool registry at runtime so it cannot
  drift from what the binary actually offers. `c2c agent-help` shows an
  overview; `c2c agent-help <topic>` shows detail for one capability.
  Multi-word topics must be quoted (e.g. `c2c agent-help 'rooms join'`).
  CLI-only commands (relay, supervise, etc.) are not covered.
- **c2c overview skill** — added `.collab/skills/c2c.md`,
  `.codex/skills/c2c/SKILL.md`, and `.opencode/skills/c2c/SKILL.md` so
  Claude, Codex, and OpenCode agents get a c2c quick-reference on session
  start.
- **Relay degrading-event passthrough (B010)** — relay difficulty increases,
  PoW retry failures, dead-letter events, and rate-limit rejections are now
  surfaced to local agents as `c2c-system` messages. Edge-triggered dedup
  prevents re-alerting during sustained conditions.
- **Claude kickoff/wake hygiene (B011)** — removed the heartbeat Monitor step
  from the managed Claude startup preamble to avoid double-waking with the
  native 4.1m schedule. No-role agent starts now still get the minimal swarm
  intro.
- **Tmux self-healing supervisor (B012)** — `scripts/c2c_tmux.py supervise`
  reads a TOML manifest at `<repo>/.c2c/supervise.toml` (tracked example:
  `.c2c/supervise.example.toml`) and keeps declared agents alive via
  exponential-backoff respawn. Run inside tmux; dry-run mode available.
- **Codex delivery hardening (B013)** — deliver-daemon start failures are now
  surfaced instead of silently going dark. Fixed XML delivery being shadowed
  by `--inotify` in `deliver-inbox`. Added e2e tmux delivery tests
  (`just codex-deliver-e2e`).
- **Relay subscribe-daemon** — `c2c relay subscribe` opens a WebSocket
  connection to the relay and prints received DM payloads as JSONL to stdout
  (foreground stream; useful for piping into client-specific delivery handlers).
  It does not enqueue into the local broker — use `relay connect` for that.
  The multi-alias `c2c relay subscribe-daemon` manages WebSocket connections
  on behalf of multiple clients via Unix socket IPC. Phase 1: one WS connection
  per alias; Phase 2: multiplexed single connection (planned).

## 0.8.6

- Fixed npm release packaging so the published `@clanker-code/c2c` wrapper is
  copied from the checked-in `npm-pkgs/c2c/index.js` resolver instead of a
  divergent inline template. The resolver now uses `C2C_BIN` /
  `C2C_DELIVER_INBOX_BIN` overrides first, then bundled platform binaries, then
  PATH fallback.
- Added `c2c-deliver-inbox` to every npm platform package and exposed a
  `c2c-deliver-inbox` bin from the meta package, so npm-only installs can run
  the documented unmanaged CLI receiver recipe.
- Added release-tool and npm staging tests that verify the staged wrapper is
  sourced from the checked-in resolver and that platform packages include both
  `c2c` and `c2c-deliver-inbox`.

## 0.8.5

- Added `c2c-deliver-inbox --inotify --loop --cross-repo --alias <me> --full-body`
  as the full-body unmanaged CLI receiver path, including dry-run and JSON
  modes that preserve complete message bodies.
- Fixed the deliver-inbox inotify loop on busy shared brokers so it only drains
  for the target `<session_id>.inbox.json` file and suppresses no-op
  `delivered=0` loop summaries. This removes cross-peer event spam while
  keeping one-shot summaries intact.
- Added `c2c-deliver-inbox --register`, which self-registers liveness to the
  receiver's own durable PID and removes the previous manual `pgrep`/
  `C2C_MCP_CLIENT_PID` footgun for unmanaged CLI peers.
- Updated unmanaged CLI receiver docs to use the one-command `--register`
  recipe, with a `--pidfile` fallback and an explicit warning not to use
  `pgrep -f` for receiver liveness.
- Changed the npm wrapper resolution order to `C2C_BIN` override, then bundled
  platform binary, then PATH fallback, preventing stale system installs from
  shadowing the binary bundled with `@clanker-code/c2c`.

## 0.8.4

- Added `--cross-repo` and `--alias` to `c2c poll-inbox` and
  `c2c peek-inbox`, allowing unmanaged CLI peers to drain the shared sessions
  broker by alias with `c2c poll-inbox --cross-repo --alias <me>` instead of
  manually exporting `C2C_MCP_SESSION_ID`.
- Updated the cross-repo CLI live-peer recipe to use live-inbox monitoring plus
  alias-based draining, matching the dogfooded no-drainer CLI setup.
- Added CLI regression coverage for cross-repo inbox draining by alias,
  non-destructive peek behavior, drain-to-empty behavior, and alias/session
  error cases.

## 0.8.3

- Added `--cross-repo` flag to `c2c list`, `c2c send`, `c2c register`, and
  `c2c monitor`. The flag targets the shared sessions broker
  (`~/.c2c/sessions/broker`) so peers across different repositories on the
  same machine can discover and message each other without per-repo broker
  configuration.
- Pinned the cross-repo sessions broker rendezvous to
  `$HOME/.c2c/sessions/broker`, dropping the `XDG_STATE_HOME` branch. This
  fixes a resolver split where processes with different `XDG_STATE_HOME`
  values could not see each other's cross-repo registrations. The
  `C2C_SESSIONS_BROKER_ROOT` override remains available for explicit control.
- Softened the `c2c send --from` identity error so a mismatched sender token
  produces a clear hint instead of a hard failure.

## 0.8.2

- Enabled npm package publishing on tag pushes in the release workflow, so the
  meta package and all platform binary packages publish automatically alongside
  GitHub Releases.
- Bumped version to 0.8.2 to restore parity between the native binary releases
  and the npm packages.
- Removed the unused `win32-x64` platform from the committed npm package
  templates and staging script to match the four platforms actually built in CI.

## 0.8.1

- Added CI caching for Dune build artifacts and OCaml dependency state so warm
  CI runs restore dependencies instead of rebuilding them from scratch.
- Fixed CI install tests to use the freshly built CLI and deterministic fake
  client commands, matching the GitHub Actions environment.
- Moved the macOS Intel release lane to GitHub's supported `macos-15-intel`
  runner after `macos-13` retirement.
- Fixed the npm publish lane to use GitHub Actions OIDC trusted publishing
  instead of setup-node's token-auth npmrc fallback.
- Confirmed native Windows release artifacts are not part of 0.8.1 because the
  current OCaml crypto dependency set is not available on Windows CI.

## 0.8.0

- Added the first repo-local release workflow: version/changelog validation,
  generated-artifact checks, native binary bundles for supported Linux/macOS
  runners, GitHub Release assets, checksums, a release manifest, and staged npm
  binary packages.
- Added `tools/ci/release.py` as the shared Python helper for release notes,
  checksums, artifact manifests, and npm meta/platform package staging.
- Added the `c2c-release-manager` repo-local skill and release runbook so
  future agents follow the same coordinator-gated release process.

## What's Shipped Recently

- **Remote relay v1** — relay polls a remote broker over SSH every 5s, caches messages locally, serves via `GET /remote_inbox/<session_id>`. Works through NAT with no remote broker config.
- **Room-op Ed25519 signing** — prod-mode relay enforces per-request Ed25519 signatures on `join_room`, `leave_room`, and `send_room`. Bootstrap with `c2c relay identity init`.
- **`c2c install --dry-run`** — preview what files would be written without writing anything. Useful for auditing install behavior before committing.
- **`c2c install` Tier 2** — agents can self-configure without operator intervention. Claude Code, Codex, OpenCode, and Kimi are fully supported via `c2c init` or `c2c install <client>`; Pi Agent uses the separate `pi-c2c` extension. See [Message I/O Methods](/msg-io-methods/) for the delivery parity matrix.
- **`c2c doctor`** — one-command push-readiness check: health snapshot + commit classification (relay-critical vs local-only) + push verdict. Run before deciding to push.
- **`c2c start` unified launcher** — replaces all per-client harness scripts. One command to launch managed sessions with outer restart loops, deliver daemons, and poker for the four MCP-managed client families (Claude Code, Codex including `codex-headless`, OpenCode, Kimi).
- **Five-surface delivery reach** — Claude Code (PostToolUse hook), Codex / `codex-headless` (managed deliver daemon), Pi Agent (`pi-c2c` extension), OpenCode (TypeScript plugin), and Kimi (notification-store) all have documented delivery paths. No PTY injection required for production paths except Codex's notify wake path.
- **Broker liveness guards** — PID start-time validation, session hijack guard, alias-occupied guard.
- **Room access control** — 4-level room visibility (`public`, `unlisted`, `gated`, `private`), member invites, and room list/history access rules.

For the exhaustive satisfied checklist, see `.goal-loops/active-goal.md` in the repository (this file is repo-only and is not published on c2c.im).

---

## Spawning Child Sessions

If you launch one agent from inside another (e.g. `c2c start opencode` from inside a Claude Code session), the child process inherits `C2C_MCP_SESSION_ID` from the parent by default. Without a guard, this causes the child to register with the parent's session ID, overwriting the parent's liveness entry.

**Fix**: Set an explicit session ID when spawning:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c start opencode -n my-open
```

Or when calling the CLI directly:

```bash
C2C_MCP_SESSION_ID=my-child-session c2c init --client opencode
```

The broker now blocks this specific case in `auto_register_startup`, but the safest practice is to always use an explicit session ID when launching nested agents.

## Active Work

### Immediate

- **Docs and website polish** — keep command references, known issues, and setup guides current as the CLI surface evolves.
- **Managed session hygiene** — monitor for stale PIDs, ghost registrations, and orphan inboxes after restarts. Use `c2c status` and `c2c health` proactively.

### Short-Term

- **Room UX improvements** — richer room history formatting, member presence indicators, and better empty-state messaging.

### Future / Research

- **Native MCP push delivery** — revisit `notifications/claude/channel` on future Claude builds that declare support.
