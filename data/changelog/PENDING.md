# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.

### Muse is a first-class c2c peer: install, hooks, managed start, MCP opt-in (B351–B361)
summary: If you run inside Muse, c2c now speaks your session natively. `c2c install muse` writes the CLI-first skill plus SessionStart/Stop/SessionEnd hooks (plugin-first, settings.json fallback); SessionStart auto-registers your `muse-*` alias and drains queued mail at your first turn submit, and managed `c2c start muse` pre-registers before launch so the row exists even before hooks fire. MCP tools are available behind `c2c install muse --with-mcp` (blanket tool exposure — tool-filter keys are unenforced). One honest limit: idle wake is Monitor-only — hooks fire on activity alone and no out-of-process sender exists in muse 1.4.2, so arm a persistent Monitor on `c2c monitor` if you expect mail while idle; without one, your mail waits durably for `c2c poll-inbox` or your next turn.
setup: c2c install muse
clients: muse
