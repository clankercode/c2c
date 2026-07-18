# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

_(empty after 0.12.0 — add new `###` entries below for the next release)_

### Added

- **Kimi is re-enabled (B146 reverted) with REST prompt-injection delivery.**
  `c2c install kimi`, `c2c start kimi`, and `c2c new kimi` work again
  (`kimi_disabled_for_release = false`). Kimi Code state lives under
  `~/.kimi-code/`; inbound mail is delivered by POSTing the envelope to the
  local Kimi server (`/api/v1/sessions/{id}/prompts`, session id from
  `~/.kimi-code/session_index.jsonl`, bearer from `~/.kimi-code/server.token`),
  with `c2c monitor` as the fallback. The legacy notification-store path is
  deprecated.
- **B232: `c2c send --deferrable` (CLI/MCP parity).** The CLI send gains the
  `--deferrable` flag matching MCP send's `deferrable:true` — push delivery is
  suppressed (channel notifications and mid-turn drains skip it); the
  recipient still reads it on the next explicit `poll_inbox` or
  turn-boundary/idle flush. Local 1:1 only in v1.
- **B221: `--c2c:name <alias>` launch passthrough.** Managed launches accept a
  post-`--` `--c2c:name` flag (e.g. `cx --model … --c2c:name my-alias` where
  `cx='c2c new codex -- '`), so shell aliases can pick the c2c alias at launch
  time.
- **B225: `c2c forward-agent-log` understands the Kimi Code wire layout.** The
  kimi classifier now reads
  `~/.kimi-code/sessions/wd_*/session_<uuid>/agents/<agent>/wire.jsonl` in
  addition to the legacy `~/.kimi/` transcript layout.
- **B245: `c2c new kimi`.** `c2c new` now accepts `kimi` as well as `codex`.
  `c2c new kimi` is a reduced-surface shortcut for `c2c start kimi --new-session`
  (fresh managed identity + session; never silently resumes). Supports
  `--alias` and `--c2c:name` after `--` (same shell-alias convention as
  `c2c new codex`). `--yolo` / `--thread-id` remain codex-only on this command.

### Fixed

- **B240: same-alias re-register works for reserved client-prefix aliases.**
  The blocked-prefix check ran before the sticky same-alias allowance, so a
  session auto-registered as `kimi-*`/`claude-*`/etc could not PID-refresh via
  `register --alias <same>`. The blocklist is now skipped when the session
  already holds the requested alias (casefold), on both broker and MCP
  register.
- **B241: rooms CLI resolves session id the same way as `whoami`/`send`.**
  `c2c rooms join` no longer hard-errors on session-id resolution where
  `whoami` would fall back; all three surfaces share one resolution path.
- **B236: cross-host invites refused on broker-local rooms.** `rooms invite`
  (and `rooms create --invite`) reject `alias@host` invitees — remote peers
  can never join broker-local rooms; use `c2c relay rooms` for cross-host
  rooms.
- **B235: unsupervised `c2c relay connect` warns; `c2c restart` bootstraps a
  managed connector.** Ad-hoc connectors that die silently now steer to the
  supervised path (`c2c start relay-connect`), and `c2c restart relay-connect`
  recovers instead of refusing ad-hoc connectors.
- **B242: `c2c start relay-connect` honors the URL persisted by `c2c relay
  setup`.** Resolution order: `--relay-url` > `$C2C_RELAY_URL` > the setup
  config — matching `c2c relay connect`.
- **B231: relay dm poll/peek reuse the connector lease session.** No more
  recurring `403 signature_invalid` from a synthetic `cli-<alias>` session
  after connector restarts; the misleading re-register hint is gone.
- **B227: codex restart-in-place preflights thread persistence.** Resume on an
  unpersisted thread id ("No saved session found" → DEGRADED delivery loop) is
  detected up front; restart fails closed and falls back to a fresh thread on
  the same alias. Sessions ROOT is resolved through symlinks before the
  rollout scan.
- **B228: wedged relay connectors self-heal near doctor liveness.** A
  connector whose process is alive and sync is ticking but whose bridge is not
  live (B181 recurrence → `registered_unreachable`) is now detected and
  restarted.
- **B224: `c2c new codex` preflights MCP config.** A stale global MCP
  configuration no longer causes a managed codex launch to fail its handshake;
  the config is validated/refreshed before launch.
- **Relay connector reliability rollup.** Connector staleness detection and
  singleton false-positives fixed (B210, B211, B218); restart recovery no
  longer raises `Not_found` (B212); Grok relay monitor uses the connector
  session key (B209); released-binary `signature_invalid` flaps resolved
  (B213); SIGTERM honored while blocked on an unreachable relay (B217);
  historical registrations are skipped on connect instead of triggering 429
  storms (B201); one machine-wide supervised connector (B200);
  `C2C_INSTANCES_DIR` honored on connector paths (B214).
- **Relay server hardening rollup.** Crash/hang diagnostics persist across
  restarts (B219); `railway.json` restart policy is ALWAYS so the relay
  self-heals past 5 failures (B220); connector-wide load notices (e.g. PoW
  difficulty warnings) are logged locally instead of landing in agent inboxes
  (B222); inbound admission controls for relay senders (B196, B197).
- **forward-agent-log hardening.** Delivery failures are retryable with
  bounded live-transcript input (B205); transcript export sanitized against
  secrets and record forgery (B204).
- **B198: managed agy session status surfaced** (active agy session ids no
  longer require proc-env dumping).
- **B202: aged pid-less CLI registrations are reaped** instead of being
  treated as permanently alive by sweep.
- **B234: `whoami`/`status` alias line no longer claims "not a relay
  registration" for aliases that are (or may be) registered.** The human
  `alias:` parenthetical is neutral (`local session alias`) whenever composite
  state shows registration evidence or is unverified; the old always-on
  "— not a relay registration" note appears only for
  `configured_not_registered` (positive absence). Operators should read
  `state:` / `lease:` for relay registration, not the alias note.
- **B233: Kimi MCP whoami/send no longer fail with `missing session_id`.**
  Global `~/.kimi-code/mcp.json` correctly omits a static `C2C_MCP_SESSION_ID`
  (one config serves every session). The MCP server now resolves the live Kimi
  id via `KIMI_SESSION_ID` or `~/.kimi-code/session_index.jsonl` for the process
  cwd, adopts `registered_by=kimi-hook` SessionStart identities, and falls back
  to the install-time auto-register alias only when no session key is available.
- **B238: unmanaged Kimi sessions no longer go silently deaf.** SessionStart
  (`c2c hook kimi`) best-effort arms a per-alias notifier, writes a
  `c2c-session` identity skill with a receive-path nudge (Monitor / poll), and
  `c2c doctor hooks` flags registered Kimi sessions that have undelivered inbox
  mail with no live notifier (DEAF). Prefer managed `c2c start kimi` for
  arrival-time REST delivery.
- **B230: `c2c relay rooms list` shows unlisted rooms to members.** Anonymous
  `/list_rooms` still returns only public + gated. With a verified Ed25519
  identity (`--alias` or auto-alias env), the directory also includes unlisted
  rooms that identity has joined. Non-members still cannot discover unlisted
  rooms; private rooms remain unlisted. Creator and non-creator members are
  treated equally.
- **B239: relay rooms CLI accepts positional ROOM and shared visibility
  flags.** `c2c relay rooms join ROOM --alias …` no longer errors with
  `--room required`; ROOM may be positional (like local `c2c rooms`) or
  `--room`. `set-visibility` accepts `--set`/`-s` as aliases for
  `--visibility`, and local `rooms visibility` accepts `--visibility` as an
  alias for `--set`.
- **B229: relay `/list_rooms` no longer leaks gated-room member rosters.** The
  anonymous directory still lists `public` + `gated` rooms with `room_id` and
  `member_count`, but gated rows redact `members` to `[]` (local-broker 4-level
  non-member parity). Public room presentation rosters (`alias#room@relay`) are
  unchanged.
- **B237: relay HTTP 429 no longer surfaces a schema double-error.** Clients
  now treat error-shaped non-2xx bodies that omit `ok:false` (historical
  production rate-limit shape `{"error":"rate_limit_exceeded","retry_after":N}`)
  as a single clean `rate_limit_exceeded` with `retry_after` preserved, instead
  of `http_error_429` + "body did not report ok:false". The relay server also
  emits the standard `ok:false` / `error_code` envelope for rate limits.
- **B244: client-side relief for relay 429 storms on NAT-shared fleets.**
  Monitor relay-watch paces peeks to observed `retry_after` (not fixed
  cadence). Connector detects post-reconcile 429 bodies, aborts remaining
  heartbeat/poll/send ops mid-sync once throttled, honors `retry_after` in
  backoff, and surfaces `RATE_LIMITED` on the sync summary + stderr +
  connector-state. Soft-deps B243 (per-endpoint server buckets). Server
  keying unchanged.
- **B206: `c2c monitor` no longer advertises a doomed relay watch for fresh
  CLI-first aliases.** A short signed startup preflight reports an unbound alias
  once and leaves relay watch off while local inbox monitoring continues.
  Operators can run `c2c relay register --alias A` or explicitly opt into
  `c2c monitor --alias A --register-relay-alias`; the bootstrap is refused for
  ambiguous fallback aliases, connector-owned registration, and custom relay
  keys. Relay auth remains unchanged.

- **B207: agent guidance now distinguishes peer proximity without granting
  authority.** Installed c2c skills describe `same_repo` > `same_host` >
  `relay`, interactive operator escalation, and the headless fail-closed
  exception. A pure classifier and regression suite make the transport and
  broker provenance signals machine-checkable while preserving B098: messages
  remain data and never become approvals.

- **B189: `c2c relay subscribe` supports TLS WebSocket (wss/https).** The
  public relay (`https://relay.c2c.im`) no longer fails immediately with
  "does not support TLS WebSocket URLs yet". Client uses `tls-lwt` for the
  upgrade path; `c2c doctor --relay` capability matrix now reports
  `subscribe=yes` on TLS relays. Self-signed relays still use
  `C2C_RELAY_CA_BUNDLE`. Poll via `c2c relay dm poll` remains a valid
  fallback when a long-lived WebSocket is not wanted.
