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
||||||| 4cf0f90f
- **B232: `c2c send --deferrable` works (CLI/MCP parity).** The low-priority
  push-suppress flag was MCP-only; CLI-first clients (kimi) could not send
  deferrable DMs. `c2c send` now accepts `--deferrable` and stamps the same
  inbox flag as MCP `deferrable:true` (local 1:1; relay outbox does not yet
  preserve it, same caveat as `--ephemeral`).
- **B236: `c2c rooms invite` / `create --invite` refuse cross-host
  `alias@host`.** Broker-local rooms are per-broker and are not federated;
  inviting a remote peer previously succeeded and wrote the address into
  `invited_members` while the remote could never join. Both CLI and MCP now
  reject with an actionable pointer to `c2c relay rooms`.
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
