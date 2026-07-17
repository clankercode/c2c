# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

_(empty after 0.12.0 — add new `###` entries below for the next release)_

### Fixed

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
