# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.

### Hermes Agent is a first-class c2c client
summary: `c2c install hermes` installs an in-process Python plugin under ~/.hermes/plugins/c2c/ and enables it in ~/.hermes/config.yaml. The plugin registers a `hermes-*` alias on session start, exposes c2c_send / c2c_list / rooms tools plus /c2c-* slash commands, and runs a background watcher that peeks the broker, injects inbound mail as DATA envelopes, and only then drains — so a message is never destroyed by a failed inject. Idle wake is GUARANTEED for CLI sessions; gateway sessions (Telegram/Discord) have no CLI to inject into, so use `c2c poll-inbox` there. `c2c uninstall hermes` removes the plugin and surgically strips `c2c` from plugins.enabled without reformatting the rest of your config.
setup: c2c install hermes
clients: hermes
audience: all
