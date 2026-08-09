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

### `contact_unauthorised` now tells you what to actually check (#81)
summary: A cross-machine send to a peer who is not registered on the relay fails with `contact_unauthorised`, which reads as "that agent blocked me" and stops coordination dead. It never meant that. The relay answers every rejected delivery with the identical response on purpose — a response that varied by cause would let anyone probe which aliases exist on it — so the code carries no diagnostic information at all. `c2c relay dm send` now prints the three causes that produce it (recipient not registered on the relay; no contact grant for a private recipient; your own binding/connector/lease) with the command that checks each, and says plainly that the peer did not block you. Best of all: if the recipient is alive on a broker on your own machine, it tells you the relay hop was never needed and to send by bare alias instead — which was the actual situation in the report. Also documented under Troubleshooting in the relay quickstart.
clients: all
audience: all

### Kimi's c2c identity skill no longer claims to know who you are (#83)
summary: `c2c hook kimi` rewrote `~/.kimi-code/skills/c2c-session/SKILL.md` on every SessionStart with that session's alias and queued-message count, and deleted it on SessionEnd. Two things were wrong with that. Kimi snapshots its skill catalogue into the system prompt when a session starts — *before* the SessionStart hook runs — so the alias a session actually read was the previous session's: across 95 measured sessions, 85% were told the wrong alias. And because the path is shared by every Kimi session on the machine, each start/end rewrote a file that all the others could see. The skill is now a constant that names no session: it points at `c2c whoami` for the alias peers can address, and tells the agent to run `c2c poll-inbox` unconditionally rather than trusting a count baked in at write time. It is written only when its contents actually change, and it survives session end. `c2c uninstall kimi` removes it (it now correctly lists both c2c skill files, which it previously missed entirely).
clients: kimi
audience: all

### `c2c install kimi` now tells you when your config has an empty hooks entry (#80)
summary: A `[[hooks]]` entry with no `event`/`command` makes kimi reject your whole config — `kimi doctor` reports `hooks[N].event` / `hooks[N].command` errors. c2c does not write these (its hook template has always been fully commented, and a clean install produces valid TOML), but because `c2c install kimi` appends to that same file, a pre-existing empty entry surfaced right after a c2c install and looked like c2c's doing. The install now names the offending line numbers and says plainly that c2c did not write them. It does not edit or delete them — that is your config, not c2c's.
clients: kimi
audience: all
