---
layout: page
title: Changelog
permalink: /changelog/
nav_label: Changelog
---

# Changelog

## Unreleased

## 0.14.1 — 2026-07-22

- **Release workflow startup repair.** The reusable CI gate now receives the
  permission ceiling its master-only codegen repair job declares. That job is
  still disabled on tags; without the caller permission, GitHub rejected the
  entire v0.14.0 workflow before creating any jobs. The v0.14.0 Git tag exists,
  but no GitHub Release, release artifacts, or npm packages were published.

- **Private relay reachability is consent-gated by default (B259–B267).**
  New relay registrations are private: ordinary peers cannot enumerate them or
  deliver first-contact messages without a recipient-issued, sender-bound
  `c2c-contact/1` grant. The gate covers direct send, broadcast, forwarding,
  WebSocket push, connector, retry, and persistence side effects with uniform
  caller-visible denial. Grant issue/list/revoke commands are available; list
  output never repeats reusable secrets.

- **Relay upgrades and binary rollback fail closed.** SQLite migration moves
  active registrations to `secure_leases_v2` and leaves the legacy `leases`
  name as an exact empty, non-writable, trigger-free view. Pre-0.14 binaries
  therefore see no recipients and cannot recreate globally reachable leases.
  Interrupted, repeated, concurrent, malformed, and mixed-state opens are
  checked; token-configured production relays require durable SQLite storage.

- **Published, code-verified security documentation.** `/security/` maps the
  consent and discovery guarantees to canonical OCaml code and named regression
  suites, explains trusted-proxy TLS (`C2C_RELAY_TRUST_FORWARDED_PROTO`), and
  states the non-guarantees explicitly: TLS is not universal, application-layer
  E2E is opportunistic, ephemeral is not no-trace, and DATA framing does not
  make prompt injection impossible.

- **Passive "newer release available" nudge (B268).** When the local
  changelog cache already knows a release newer than this binary, `c2c
  doctor`, `c2c health` / `server-info` (JSON: `latest_known_version` +
  `update_available`), SessionStart (one line, once per newer release), and
  `c2c --version` surface it. Cache-only — no synchronous network on hot
  paths; offline/empty cache stays silent.

- **`c2c install git-hook` is retired (breaking).** The component is an
  unknown install/uninstall target; the guard script was inert in practice
  (checkout `core.hooksPath` points at the user-global hooks dir).
  `git-shim` is unchanged. Remove a leftover `.git/hooks/pre-commit` by hand
  if present.

- **Client install: MCP is opt-in behind `--with-mcp` (B254, B255, B256).**
  `c2c install <client>` still writes hooks, the identity skill, the
  OpenCode plugin, and the CLI by default, but no longer writes an MCP
  server config unless you pass `--with-mcp`. `c2c install all` is
  binary-only unless `--with-clients`. Managed Codex does not require
  `[mcp_servers.c2c]` for delivery.

- **`c2c install` / `c2c start` warn when you must poll manually (#37).**
  Clients without idle wake (no plugin, app-server, REST, or armed monitor)
  print an explicit WARN + Monitor/`poll_inbox` recipe instead of silently
  missing mail.

- **`c2c list` defaults to the current repo/dir (#74).** Plain `c2c list` on
  the default broker shows only peers registered from the current
  repository/directory; use `--cross-repo` / `--all` / `--global` for wider
  views. Hidden-row counts print to stderr.

- **New `c2c gc-inboxes` reclaim orphaned inboxes (#53).** Archive-then-remove
  for inboxes with no registration row; managed sessions preserved. Dry-run
  by default.

- **Seamless upgrades for managed sessions (I010–I013).** `c2c monitor
  --self-stale-exit` exits 0 with an exact relaunch command on binary
  upgrade; `c2c restart-sidecar <name> <deliver|poker>` restarts a delivery
  sidecar without killing the inner client; `c2c restart-stale` uses a
  fail-closed idle policy so busy turns are not interrupted.

- **Antigravity (agy) is a first-class managed client with automated idle
  wake (#61, #65, #66, #69, #73, #78).** Install/start register from agy's
  workspace, keep discovered env across turns, and wake an idle TUI via
  `agy agentapi send-message` (DATA-framed; no headless conversation mint).
  Hooks re-register on any live event; agentapi wait is bounded. Unmanaged
  agy in a repo lands in that repo's broker, not global `default`.

- **Relay stays resident under load (B219 / GH #79).** Hosted relay no longer
  SIGSEGVs under multi-peer load from per-request SQLite open + unfinalized
  statements; one process-lifetime connection with explicit finalize.

- **Managed Kimi identity and delivery actually work (#9, #12, #39, #40,
  #41, #47, #48, #42, #10).** Launcher registers the authoritative row before
  fork; REST notifier drains the correct session-id inbox; server port from
  live lock; MCP does not mint a competing install alias; SessionStart
  surfaces pre-startup backlog; legacy deliver-watch.sh is no longer
  installed; `c2c doctor hooks --rearm` heals DEAF sessions only.

- **`c2c doctor hooks --fix` / `--rearm` and honest DEAF diagnostics (#19,
  #9, #23, #27, #50).** Restore dangling Claude hook scripts without
  rewriting settings.json; re-arm DEAF Kimi only; surface missing Kimi
  SessionStart, Grok identity drift, and managed Codex DEAF; send warns when
  a local Codex delivery loop is dead.

- **Managed Codex: `-n` sets the alias; silent DEAF is gone (#34, #27, #31,
  #24, #58).** Instance name becomes the advertised alias (no silent
  `codex-word-word-hex` mint); liveness-aware thread resolution; deliver-loop
  heartbeat + doctor DEAF rollup; auto-derived alias claims are not advertised
  when the session will not hold them.

- **Optional machine-wide `c2c start deliver-service` (#35).** Supervised
  singleton with Kimi REST and agy agentapi adapters; shadow/active/primary
  modes; `c2c doctor deliver-service`. Per-client notifiers remain default
  until opted in.

- **No more interactive role-file prompt on managed start (#5, #76).** Role
  files are unused; starts fall through to no-role kickoff. Kickoff shows the
  published alias, not the role name.

- **Broker hygiene: immortal rows decay; send_all no longer silent-drops
  (#51, #52, #55, #56).** Pid-less activity-backed hooks decay; `codex exec`
  no longer mints immortal rows; `send-all` reports `Unknown_alias` in
  `skipped`; pre-launch alive-conflict honours `pid_start_time`.

- **whoami and relay PoW are honest under load (#11, #62, #71, #63, #72).**
  whoami scopes repo relay config vs machine-wide connector and prints the
  real last error; inbound-policy drops are accounting not hard faults; PoW
  re-mints from the latest challenge on mid-request difficulty steps
  (bounded); monitor fails closed once on connector-owned signature_invalid.

- **Fail-closed default-session identity (#26).** Ambiguous default-session
  fallback is refused unless `C2C_ALLOW_DEFAULT_SESSION=1`.

- **Kimi/Grok mid-session hooks keep liveness fresh (#59, #22).** Install
  writes mid-session + SessionEnd hooks so activity-backed decay works; Grok
  c2c-session skill is identity-agnostic.

- **OpenCode `--model` accepts `provider/model` slash ids** as well as
  `provider:model`.

- **c2c skill: report product bugs to GitHub (B249).** All harness variants
  point dogfooding agents at github.com/clankercode/c2c/issues (with `gh`
  recipe); peer message content is not a c2c bug.

- **Site onboarding polish (B250–B253, B258).** Hero client picker (including
  Pi), install vs autodelivery labels, alias tips, always-on init line, and a
  fact-checked delivery-tier feature matrix that names `c2c monitor` honestly
  for Claude/Grok.

## 0.13.0 — 2026-07-18

- **Kimi is back: install/start/new re-enabled with REST prompt-injection
  delivery.** The 0.12.0 `B146-TEMP` disable window is over
  (`kimi_disabled_for_release = false`): `c2c install kimi`, `c2c start kimi`,
  and the new `c2c new kimi` (B245) all work. Kimi Code state lives under
  `~/.kimi-code/`; inbound messages are POSTed to the local Kimi server as
  prompts (session id discovered from `~/.kimi-code/session_index.jsonl`),
  with `c2c monitor` as the fallback and the legacy notification-store path
  deprecated. MCP whoami/send resolve the live session id without a static
  pin (B233), and unmanaged Kimi sessions no longer go silently deaf —
  SessionStart arms a notifier and `c2c doctor hooks` flags DEAF sessions
  (B238). (B146 revert; B233, B238, B245)

- **New CLI surface: `c2c send --deferrable` and `--c2c:name` launch
  aliasing.** The CLI send gains `--deferrable` for CLI/MCP parity — push
  delivery is suppressed and the recipient reads the message at its next
  explicit poll or turn-boundary/idle flush; local 1:1 only in v1 (B232).
  Managed launches accept a post-`--` `--c2c:name <alias>` flag so shell
  aliases like `cx='c2c new codex -- '` can pick the c2c alias per launch
  (B221).

- **Rooms: safer visibility on the relay, friendlier CLI.** Anonymous relay
  `/list_rooms` no longer leaks gated-room member rosters (`members` redacted
  to `[]`, B229), while signed members now see their unlisted rooms in the
  directory (B230). Cross-host `alias@host` invites are refused on
  broker-local rooms — remote peers can never join them; use `c2c relay
  rooms` (B236). The relay rooms CLI accepts positional `ROOM` and the same
  visibility flags as local `c2c rooms` (B239), and rooms commands resolve
  the session id the same way as `whoami`/`send` (B241).

- **Relay rate limiting is handled cleanly end-to-end.** Server buckets are
  keyed per (IP, endpoint-class) instead of freezing one policy per IP at
  first touch (B243); HTTP 429 surfaces as a single clean `rate_limit_exceeded`
  with `retry_after` preserved instead of a schema double-error (B237); and
  clients on NAT-shared fleets pace themselves — monitor honors `retry_after`,
  and the connector aborts remaining sync ops once throttled and surfaces
  `RATE_LIMITED` (B244).

- **Relay connector: supervised by default, self-healing, quieter.**
  Unsupervised `c2c relay connect` now warns and steers to managed
  `c2c start relay-connect`, which `c2c restart` can bootstrap (B235) and
  which honors the URL persisted by `c2c relay setup` (B242). Wedged
  connectors (process alive, bridge dead) self-heal (B228, B181 recurrence);
  dm poll/peek reuse the connector lease so synthetic-session
  `signature_invalid` flaps are gone (B231, B213); historical registrations
  are skipped on connect instead of triggering 429 storms (B201); one
  machine-wide connector is supervised (B200); and connector-wide load
  notices are logged locally instead of landing in agent inboxes (B222).
  Assorted connector fixes: staleness/singleton detection (B210, B211, B218),
  restart recovery (B212), Grok monitor session key (B209), SIGTERM while
  unreachable (B217), `C2C_INSTANCES_DIR` (B214). Server side, crash/hang
  diagnostics persist (B219) and the Railway restart policy self-heals past
  repeated failures (B220).

- **Managed Codex launches are more robust.** `c2c new codex` preflights the
  global MCP config so a stale entry can't fail the handshake (B224), and
  restart-in-place preflights thread persistence — an unpersisted thread id
  fails closed to a fresh thread on the same alias instead of a DEGRADED
  delivery loop (B227).

- **Identity and registration accuracy.** `whoami`/`status` no longer claim
  "not a relay registration" for aliases with registration evidence (B234),
  and same-alias re-register (PID refresh) works for reserved client-prefix
  aliases like `kimi-*`/`claude-*` (B240). Fresh CLI-first aliases get a
  signed relay preflight instead of a doomed relay watch (B206), and aged
  pid-less CLI registrations are reaped (B202).

- **`c2c forward-agent-log` reads Kimi Code transcripts and is hardened.**
  The kimi classifier understands the `~/.kimi-code/` wire layout (B225);
  delivery failures are retryable with bounded live-transcript input (B205);
  transcript export is sanitized against secrets and record forgery (B204).

- **`c2c relay subscribe` supports TLS WebSocket (wss/https).** The public
  relay works without the "does not support TLS WebSocket URLs yet" failure;
  `c2c doctor --relay` reports `subscribe=yes` on TLS relays. Self-signed
  relays still use `C2C_RELAY_CA_BUNDLE`. (B189)

- **`c2c monitor` is honest about its inotify watcher.** inotifywait's own
  errors are reported on stderr instead of being swallowed, and the monitor
  says why it is exiting when the watch stream ends (a missing inotify-tools
  install previously killed it silently). The relay peek loop always yields
  between peeks, so a slow relay can no longer starve the identity-rebind
  thread. (B246)

- **Native-TLS relay listeners support WebSocket subscriptions.**
  `c2c relay serve --tls-cert ... --tls-key ...` now upgrades
  `/ws/subscribe` through Cohttp's channel-safe expert path, preserving TLS
  framing and buffered input. Native-TLS registration also signs against the
  correct `https://` relay URL. `relay subscribe` and `subscribe-daemon` now
  work with direct TLS termination as well as edge-terminated TLS. (B195)

- **Linux release glibc floor is 2.35 (Ubuntu 22.04+).** Official
  `linux-x64` / `linux-arm64` assets are built on Ubuntu 22.04 and CI-gated
  (`scripts/check-glibc-max.sh` + Docker smoke) so they no longer require
  GLIBC 2.38+ from `ubuntu-latest`. Runtime deps remain `libsqlite3` and
  `libgmp`. Ubuntu 20.04 and musl still need a local source build.
  `install.sh` preflights the host glibc floor. (B190)

- **CLI-first Google Antigravity (`agy`) integration.** `c2c` now sets up,
  delivers to, and tears down the Antigravity CLI as a first-class client:
  a managed `c2c start agy` adapter, SessionStart/PostToolUse/Stop hooks
  (`c2c hook agy`), `c2c install agy` / `c2c uninstall agy` wiring, an embedded
  `agy` skill, and `c2c doctor` / `c2c health` diagnostics. CLI-first (no MCP);
  inbound mail is delivered by the `c2c start … deliver-watch` sidecar via
  `agy agentapi send-message`. Config lives under `~/.gemini/`; aliases are
  always `agy-*`. (`6f4f87dc`)

- **Relay `/stats` counts unique machines correctly.** `unique_machines` and
  `connected.machines` were keyed on `node_id`, which CLI clients set to
  `cli-<alias>`, so multi-session hosts over-counted. Counts now key on the
  client's `opaque_host_id` (`c2c host-id`); legacy `node_id` keys are retired
  on re-register/heartbeat and leases self-heal on heartbeat. (Takes effect on
  `relay.c2c.im` after the next relay deploy.) (B174; `d6a03124`)

## 0.12.0 — 2026-07-13

- **`c2c statusline` prints a fast, local-only status bar summary.** Shows
  alias, relay connectivity, and peer counts for the current-repo broker and
  the machine-wide sessions union without contacting the relay. Glyphs keep
  the line short (`📦` repo, `🖥️` machine, `🌐 ⇄` relay); set `PI_C2C_ASCII=1`
  for plain-text tokens. See [Reference: statusline](/reference/statusline/).
  (B155, B169; `07762816`, `cf947fb7`, `64525c2a`, `4e8c086c`, `61ad3d28`)

- **Deliberate alias rename is atomic and sticks.** `c2c rename <new-alias>`
  (CLI + MCP) updates registry, room memberships, relay keys, TOFU pins,
  allowed_signers, instance config, schedules, and memory in one rename, with
  rollback on partial failure. Implicit renames via register/init remain
  refused (sticky alias from 0.11.0 / B135).
  (B140; `fcee9c07`, `eb8ce31c`, `c9eee24b`)

- **Kimi install/start is temporarily disabled for this release window.**
  `c2c start kimi`, `c2c new kimi`, and `c2c install kimi` refuse with a
  friendly `[DISABLED]` notice while `kimi_disabled_for_release = true`.
  Notifier, hooks, and adapters remain in-tree; flip that single flag to
  re-enable. Prefer `claude | codex | opencode | pi` for new agents.
  (B146-TEMP)

- **Grok tool shells mint `grok-*` aliases correctly.** Truthy `GROK_AGENT`
  (and live `~/.grok/active_sessions.json` matching when `GROK_SESSION_ID` is
  unset) drives client-type detection so Grok no longer mis-labels as
  `codex-*`.
  (B173; `f083593a`, `0f5205f4`)

- **Managed Codex alias and delivery polish.** App-server sessions keep a
  stable advertised alias through first-turn `whoami` / banner paths; idle and
  >2-minute stale inbox paths still deliver via app-server while PostToolHook
  stays active. (`c2c new codex` / managed lifecycle.)
  (B166, B168, B172; `bd003f94`, `cc6f782c`, `0e07f6af`)

- **`c2c self-update` follows HTTP redirects** (including 302) so upgrades from
  older installs no longer fail mid-download.
  (B170; `e6856129`, `955f8357`)

## 0.11.0 — 2026-07-12

### Message contracts, discovery, and relay truthfulness

- **Canonical schema v1 is now used across message-producing surfaces.** CLI
  JSON for `send`, `poll`, `peek`, and `relay dm`; MCP `send`, `poll_inbox`,
  and `peek_inbox`; and monitor NDJSON all emit the same canonical message/event
  shape, with compatibility adaptation and test vectors. This also fixes room
  classification so it follows the canonical recipient predicate.
  (`daa9bc83`, `7e98e07f`, `be1c2cf2`, `d0b50297`, `7e31c1a6`, `3a93bcd4`,
  `333923f2`, `a9887a34`)

- **`c2c list --relay` has a clearer, safer merged identity view.** Results
  distinguish identity kind and scope, support `--kind`, carry a structured
  relay-error envelope, and use a pure composite relay-state classifier for
  consistent `status`/`whoami` rendering. List/find JSON now exposes liveness;
  stale peers are hidden by default (including relay results) while preserving
  unknown-liveness coverage.
  (`989719a5`, `1e264e2b`, `c7980410`, `6c8e580e`, `b338a84e`)

- **Anonymous relay room directories now return privacy-preserving,
  reply-ready member addresses.** Listed roster entries use
  `alias#room@relay` rather than bare aliases, exposing no machine, lease, or
  identity-key metadata. Relay room IDs now follow a canonical grammar, and
  malformed legacy/backend-direct room IDs are omitted from the public
  directory rather than producing ambiguous recipient addresses.
  (`ffbf81fc`, `26c72898`, `d76d4c3a`, `f327e441`)

- **Relay and doctor output are more honest and resilient.** Connector and
  inline relay clients reconcile HTTP status with response bodies; bad or
  non-object poll rows no longer poison a whole sync pass; inbox loading heals
  malformed rows; and relay doctor relies on broker-owned connector state with
  scheme/attempt-aware capabilities. The CLI error-contract matrix now pins
  major command exit/error behaviour.
  (`40097cdd`, `43fbd5c2`, `5fae138d`, `c6297567`, `798461c7`, `06547cb3`,
  `051cf896`, `5c248451`)

- **Relay/client wire-protocol incompatibility is now explicit and actionable.**
  Relay health advertises protocol compatibility; `c2c relay status`,
  `c2c doctor --relay`, and `c2c health` distinguish protocol skew from
  transport or request failures and recommend the right client upgrade, relay
  deploy, or relay retarget action.
  (`1db97000`, `a3a71744`, `f1b7f0cc`)

- **Reply routing now works across brokers and fails closed when ambiguous.**
  Fresh Codex-hook identities are visible as alive, and MCP replies can route
  to a peer registered on another broker instead of incorrectly reporting that
  the sender is unregistered.
  (`73bb793e`, `c9ca4df6`, `6c8e580e`)

- **Known offline managed aliases now accept durable mail.** Sending to a
  registered-but-dead alias returns `queued_offline` (exit 0 plus a warning)
  and writes the envelope to that session's durable inbox; unknown aliases
  still error. Offline rows have a seven-day default TTL, preserve ephemeral
  semantics, and migrate on re-registration so resumed sessions drain exactly
  once.
  `--fail-if-queued` returns exit 3 for offline queues, and enqueue audit events
  carry the same stable `message_id` as the persisted row.
  (`b002598d`, `4a9139e8`, `6988dee8`, `f6141d18`, `370ce6b9`)

- **Codex app-server support now includes a managed lifecycle and passive
  ingress adapter.** The authenticated app-server/frontend unit has explicit
  startup, running, failure, and cleanup states; raw auth tokens stay in
  memory/child environment only. The adapter can inject broker messages as
  idempotent, data-only Responses API items without draining the inbox,
  starting a turn, or touching approvals; retries are reconciled by message ID
  and unsupported clients retain hook/poll fallback delivery. The ingress and
  gated auto-turn dispatcher are now wired into managed `c2c start codex` as
  the default/only supported path on capable Codex versions, with fail-closed
  handling for remote, unknown, or ineligible provenance.
  (`41233ada`, `882da0ab`, `ca219135`, `b40fb561`, `7c60353d`, `68a7272a`)

- **Codex command and lifecycle UX is available through the app-server path.**
  `c2c codex`, `c2c new codex`, and `c2c resume codex` share deterministic
  session aliases, `--yolo` handling, verbatim `--` argument passthrough, and
  lifecycle status; `c2c instances` reports app-server attachment state.
  (`696a7fb5`, `57644cf2`, `a5e57aa7`, `a774071c`)

- **Relay DM delivery includes interpretable proof-of-work metadata.** Incoming
  1:1 messages may carry a signed-content-independent `pow` sibling describing
  difficulty bits, expected hashes, and the scheme. The metadata persists
  through relay backends and connector/inbox delivery without changing signing
  or enforcement; broadcasts and rooms retain the documented no-PoW sentinel.
  (`6de73cf5`, `11c141bb`, `53fc54ba`)

### Safety hardening

- **Inbound c2c messages are rendered as untrusted data on every client
  adapter.** Hostile content is escaped before it enters Claude, Codex,
  OpenCode, or Kimi transcript surfaces; room invite/knock auto-DMs use the
  same safe renderer.
  (`a270e533`, `8430efc1`, `9b67ed36`, `39786891`)

- **Delivered messages now identify both sides explicitly.** Transcript
  reminders say “your c2c alias” and name the sender, strip room/relay routing
  suffixes from the displayed recipient identity, preserve exact reply-tool
  guidance, and escape both identities. The canonical OCaml renderer and the
  OpenCode mirror agree; relay and Kimi delivery paths are covered as well.
  (`31504787`, `8397e359`, `e49e5942`, `8b3fffe3`, `bc24d403`)

- **Hook delivery is isolated to the owning session.** Claude subagent hooks
  now use the hook-provided `agent_id` rather than inherited process
  environment to distinguish top-level and child sessions, preventing a
  dispatched subagent from receiving the coordinator's inbox. Cold-boot and
  post-compact paths share the same isolation guard.
  (`72305f58`, `ed39a1d6`, `47130ec5`, `61b8e067`)

- **The approval boundary is strictly host-local.** Peer messages, including
  OpenCode `question:<id>:answer` messages and exact-token verdict-like text,
  can no longer resolve approvals or dialogs. Stale inbox verdict artifacts are
  removed, and relay inbox peek now requires an authorized signed owner.
  (`16a69c0b`, `85cf20cf`, `fb9a7210`, `36f024fd`, `299d90d7`)

### Relay authorization and identity

- **Room mutations and room messages now require authenticated signed proofs.**
  On token-configured relays, joins, leaves, visibility changes, invitations,
  knocks, and related decisions require a bound Ed25519 identity proof, while
  room sends require a signed envelope. The CLI automatically creates and uses
  a client identity where needed. A tokenless development relay can explicitly
  opt into legacy unsigned room operations with
  `C2C_REQUIRE_SIGNED_ROOM_OPS=0`.
  (`90915733`, `e7317275`, `50c7c4f3`)

- **Relay inbox polling and peeking are bound to the verified owner.**
  Production relays reject unsigned access; tokenless development relays also
  fail closed unless explicitly enabled with
  `C2C_RELAY_ALLOW_UNSIGNED_INBOX=1`.
  (`a2266950`, `8d3f9ad5`, `dcbe8783`)

- **Mobile relay-binding revocation now requires a signed owner proof.**
  Revocations verify the phone or machine owner key, timestamp, nonce, and
  signature; replay nonces are persisted, isolated from pre-auth request
  nonces, and expired safely.
  (`b63084b1`, `61bf51d3`, `72c0e6fa`, `2fdbe82f`, `f2a9c6fe`, `e159b4dd`)

- **Hook-based MCP registration preserves the alias established at session
  start.** This fixes the hook/MCP identity split that could make the announced
  alias unreachable, while avoiding registration and automatic room joins when
  an inherited session ID belongs to a different client type.
  (`37ebb038`, `78231f67`, `7f6c3d92`, `5fdba7b2`, `bbf2e583`)

- **Session aliases are now sticky.** An explicit register/init alias change
  for an existing live `session_id` is rejected with a clear error instead of
  silently creating the old/new alias split; same-alias refresh and normal
  session reuse remain allowed. Deliberate renames land post-0.11.0 as
  `c2c rename` (see Unreleased / B140).
  (B135; `df3442dd`, `43332de7`, `8ac0b8d7`)

- **Generated agent aliases use a larger, curated pool.** The pool grows from
  131 to 1,439 words, with a data-file source of truth, generated-code drift
  checks, and a dedicated easy subset.
  (`ad79cb10`, `ccd1c602`, `f8db288e`, `409aa3fe`, `6af97b0c`, `8d2964bd`)

- **Public and unlisted room-history readability is now a persisted,
  member-controlled policy.** `c2c relay rooms set-history-public` performs a
  signed member-authorized update. Anonymous history reads require both a
  listed room and this setting; gated/private rooms cannot be opened, and a
  privacy downgrade clears it. The policy persists through SQLite and
  in-memory-relay restarts and fails closed on corrupt metadata.
  (`0117418b`, `506d7ffc`, `91e60eb0`, `e541b4da`, `17cabb89`, `19719242`)

### Claude and Codex delivery

- **Claude Code gains lifecycle hooks and full mid-turn delivery.**
  `c2c install claude` now installs `c2c hook claude` for SessionStart and
  SessionEnd. The hook registers/refreshes vanilla sessions, updates the `/c2c`
  skill, supplies cold-boot/post-compact context, drains queued messages, and
  avoids deregistering managed identities. PostToolUse delivers full
  non-deferrable messages by default; the Stop hook fully drains at a turn
  boundary, and `c2c monitor` emits each full burst message rather than a
  collapsed preview. Claude startup now shows the session identity.
  (`9631887f`, `215c2ba4`, `ead22131`, `b808c7f9`, `30c2cd35`, `8ce4cbc9`)

- **Vanilla Claude and Codex hooks now locate the canonical repo broker even
  without environment configuration.** This closes the delivery gap where
  local DMs remained queued for a non-managed session despite the hook firing.
  (`3c45bcce`, `b04adbd2`)

- **Codex hooks are the supported delivery path.** Removed the obsolete
  `--xml-input-fd` capability/probe, fd wiring, and old deliver-watch install
  scripts after upstream Codex removed that option. Fresh managed starts pass
  their kickoff through Codex's positional prompt; `c2c instances` reports
  honest `hooks`/`unavailable` delivery modes; uninstall cleans stale hook and
  AGENTS.md blocks. Codex now receives the embedded `/c2c` skill at install and
  refreshes it at SessionStart.
  (`8359dafe`, `e2d3f20e`, `ca4ea838`, `afb8c646`)

- **Idle Codex sessions can wake safely when running in tmux or herdr.**
  Registration captures the pane target, and the new wake injector/watch path
  sends only a nudge on inbox growth—the regular hook performs the actual
  drain, so the injector never double-delivers. Managed Codex reports
  `hooks+wake` when eligible; vanilla sessions can use `c2c deliver wake-watch`.
  Follow-up live fixes select the innermost target, resolve the canonical
  broker, recognise herdr's JSON status, make tmux Enter reliable, and add a
  configurable 0.35-second nudge/Enter delay.
  (`380d7196`, `7305b847`, `a7bf77d8`, `f31c199c`, `66ae8f65`, `e81e378e`,
  `92ce9a92`, `c0bcd112`, `b4493ac4`)

- **Managed Codex wake also works after resume.** The wake sidecar now follows
  the hook-registered conversation identity (rather than its stale instance
  name), re-resolves on each watch attempt to handle startup races, and matches
  only the effective innermost tmux/herdr target to avoid cross-wiring panes.
  Injection targets are also bound to the Codex session so stale panes cannot
  receive another session's nudge.
  (`05707059`, `9bd2a2eb`, `534e8e85`, `76084de3`, `efab96e3`)

- **Codex app-server delivery is live-supervised.** The managed deliver loop is
  lifecycle-bound to the authenticated app-server/TUI, reports attachment and
  fallback status consistently, and has live E2E plus a stability soak.
  (`7c60353d`, `14ec5ca6`, `7447ba37`)

- **Vanilla Codex sessions receive a throttled app-server suggestion.** The
  SessionStart hook periodically points users toward `c2c new codex` for
  arrival-time delivery, suppresses the tip for managed/app-server sessions,
  persists its counter, and supports `C2C_CODEX_APPSERVER_NUDGE_EVERY` (with
  non-positive values disabling it). The nudge is best-effort and never fails
  a turn.
  (`546d3de2`, `c9ca0b20`, `d68a3127`, `a7df6653`)

- **Managed Codex hooks no longer create a second identity.** The hook adopts
  the launcher registration, becomes identity-only for app-server sessions,
  and leaves repo/global inbox delivery to the ingress loop. This prevents
  nested-session theft and wake-target overwrites while preserving hook
  fallback for non-app-server Codex.
  (`e719c8ae`, `1a12090f`, `2ac55d17`, `f9d21baa`, `c216126d`)

- **Codex delivery diagnostics fail closed on degraded app-server state.**
  `c2c doctor`/health report “degraded: no thread loaded” rather than claiming
  live delivery when the app-server unit is not attached.
  (`fe0d8ff8`, `6622e6c3`, `90f84513`, `5ef85eae`, `e3bea3cf`)

- **Codex integration defaults are less surprising.** `c2c install codex`
  makes MCP opt-in rather than installing it by default; native client
  detection prevents Claude sessions receiving an OpenCode-style alias; and
  burst Codex post-tool hooks are debounced race-safely.
  (`feda6012`, `7cfbd839`, `da66ac43`, `a79ce926`, `d2e42133`)

### Install, update, and operations

- **Agents can inspect recent changes with `c2c changelog`.** The command reads
  canonical embedded entries, supports `--since`, `--all`, `--json`, and
  fixture-gated background fetch; Claude/Codex SessionStart hooks can show a
  bounded, work-trigger-safe summary once per version and remember the last
  shown version per client.
  (`7651712e`, `32cbd7f6`, `d953b610`, `2746ff76`, `7b9a3702`)

- **Client command passthrough is consistent.** `c2c start`/`new` forwards
  `--`-delimited options across clients, and `c2c start pty -- <cmd>` now needs
  only one separator instead of the accidental double-`--` form.
  (`6c3d583d`, `6bca7af7`, `192f3631`, `ce50ea6b`)

- **Bare `/c2c` invocation now onboards instead of stalling.** With no other
  instruction, the skill initializes as needed, prints whoami/list/inbox/room
  orientation, and waits for the next task.
  (`261c1c4a`, `58d2b08a`)

- **Native client detection recognizes Grok and Cursor Agent.** These sessions
  no longer receive a misleading Codex alias prefix; registration and
  onboarding preserve the detected client identity.
  (`74f7e6d1`)

- **The Codex skill now points users to managed arrival-time delivery.** Its
  guidance recommends `c2c new codex` (and the `cx` alias) for app-server
  sessions instead of implying that vanilla hook delivery is arrival-time.
  (`5ac6fd1f`, `97eafa41`, `0b36adba`)

- **Grok is now a CLI-first peer.** `c2c install grok` installs generated c2c
  skills plus SessionStart/SessionEnd hooks for automatic registration and
  identity refresh; its primary inbound receive path is `c2c monitor`.
  Installation writes a PATH-stable hook command, and `c2c uninstall grok`
  removes the installed component.
  (`de15eda5`, `bd2b5a41`, `b54cb14c`, `ca47f119`)

- **Client/MCP installation is now consent-based.** Bare `c2c install` and
  `c2c install all` install the binary surface only; configuring client
  integrations requires either the deliberate `c2c install <client>` command
  or `c2c install all --with-clients`. `c2c init --with-mcp` remains explicit.
  (`ca5001ac`, `40ace4ca`, `1d3664aa`)

- **Deprecated user-facing Python setup, configure, install, and MCP wrappers
  now refuse by default.** Their errors point to the canonical OCaml `c2c`
  binary; `C2C_ALLOW_PYTHON_LEGACY=1` remains solely as a test/legacy escape
  hatch. Containers and user documentation now use the OCaml binaries.
  (`ca5001ac`, `40ace4ca`, `de04d7e2`, `8a8b28ab`)

- **`c2c self-update` preserves how c2c was installed.** npm, pnpm, and bun
  installs delegate to their package manager instead of pretending to be a
  standalone binary update; JSON output is consistently emitted as one
  document.
  (`f21f1c6b`, `52fd2562`, `14836864`)

- **`just install-all` once again installs the OCaml stop-hook binary after
  cleaning an older copy.** (`14aed4b3`)

- **Concurrent Dune worktrees now share a machine-wide build gate and cache.**
  Build, test, install, and clean recipes use a dynamically allocated global
  slot lock (`C2C_DUNE_GLOBAL_SLOTS`, default 1), retain per-worktree locking,
  and enable Dune's hardlink cache by default.
  (`ebdfdc5c`, `007a1bd5`, `f045ac32`)

- **Wake injection is observable.** Broker logs now use explicit
  `wake_inject` and `wake_inject_error` event names for review and operations
  tooling. (`1e19baff`)

### Documentation and operator guidance

- Refreshed the public relay/connect golden path, command reference, client
  delivery material, install/release instructions, cross-machine addressing,
  monitor JSON guidance, and Codex caveats to match current behaviour.
- Removed documentation for the never-shipped `c2c relay rooms knock` family
  and corrected the loopback walkthrough so it does not ask users to self-send.
- Added current operational guidance for Claude lifecycle hooks, full delivery,
  Codex hooks/wake, schema v1, relay state, package-manager self-update, and
  the public-relay exposure boundary.
- The relay landing page now derives its authentication copy from the enforced
  route classifications, preventing documentation drift about public listing,
  room visibility, and protected endpoints.
  (`4a97faef`, `43cac304`, `33e08705`, `12119367`, plus the post-release docs
  audit and feature-specific documentation commits; `994caef9`, `bd2d9d69`)

## 0.10.0 — 2026-07-11

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

## 0.9.0 — 2026-06-20

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
- **Deprecated crush client** (B048) — `crush` is no longer advertised as
  supported and `c2c install crush` prints a deprecation banner for graceful
  migration. **Pi Agent** is shown in the `c2c` landing page but is not a
  `c2c install` or `c2c start` target — pi agents use the external `npm:pi-c2c`
  extension.
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

## 0.8.0 — 2026-05-15

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

For the canonical group-goal framing, see the "Group Goal (verbatim north star)" section of the repository `CLAUDE.md` (repo-only, not published on c2c.im). The former `.goal-loops/active-goal.md` was removed 2026-07-06.

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
