# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

_(empty after 0.12.0 — add new `###` entries below for the next release)_

### Fixed

- **B189: `c2c relay subscribe` supports TLS WebSocket (wss/https).** The
  public relay (`https://relay.c2c.im`) no longer fails immediately with
  "does not support TLS WebSocket URLs yet". Client uses `tls-lwt` for the
  upgrade path; `c2c doctor --relay` capability matrix now reports
  `subscribe=yes` on TLS relays. Self-signed relays still use
  `C2C_RELAY_CA_BUNDLE`. Poll via `c2c relay dm poll` remains a valid
  fallback when a long-lived WebSocket is not wanted.
