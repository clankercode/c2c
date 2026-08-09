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

### c2c no longer burns Grok context on skill-catalogue churn (#82)
summary: `c2c hook grok` wrote its `c2c-session` identity skill on every SessionStart and deleted it on every SessionEnd, at a path shared by every Grok session on the machine. Grok re-announces its entire skill catalogue to each live session whenever the set of skills it can see changes, so that one skill appearing and disappearing — a ~331-byte catalogue entry — cost every *other* concurrent Grok session a ~59 KB (~14.7k token) re-announcement — 178x amplification, and 30.5% of all recorded session history across 232 measured sessions. The skill is now written only when its contents actually differ and is never removed at session end, so the skill set stays constant and concurrent Grok sessions keep their context for their work. `c2c uninstall grok` still removes it. No action needed beyond updating c2c.
clients: grok
audience: all

### c2c no longer changes the permissions or symlinks of your config files (#84)
summary: c2c writes config files you own by writing a temp file and renaming it into place. A rename replaces the file rather than editing it, so two things quietly changed every time: your file's permissions were reset to the default (a 0600 config came back 0644), and if the path was a symlink — a common dotfiles setup — the link was replaced by a regular file, silently detaching it from wherever it pointed. c2c now reads the existing permissions and reapplies them before the rename, and follows symlinks so the link survives and its destination is what gets rewritten. c2c will not tighten a file it did not create, so if a shared config is world-writable `c2c health` now reports it (`shared_config_modes`) and leaves the decision to you.
clients: all
audience: all
