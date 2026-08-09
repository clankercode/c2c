# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.
