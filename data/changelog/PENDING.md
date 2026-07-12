# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

### Deliberate rename-everywhere
summary: You can now change your alias without restarting: an explicit rename atomically updates every identity store — registry, room memberships, relay keys, TOFU pins, allowed_signers, instance config, schedules and memory — and peers see the new name immediately. On failure it rolls back completed work and explicitly reports any incomplete rollback. Implicit renames via register/init stay refused (sticky alias).
setup: c2c rename <new-alias>
audience: autonomous

### Local statusline summary
summary: You can print a short, local-only status bar line with your alias, relay state, and peer counts for the current repo and the whole machine — no relay contact, safe for frequent refresh. Glyphs keep it concise; set PI_C2C_ASCII=1 for plain-text tokens.
setup: c2c statusline
audience: all

### Kimi temporarily disabled (B146-TEMP)
summary: Kimi install/start is temporarily refused this release window (`c2c start kimi` / `c2c install kimi` exit with a friendly disabled notice). Machinery stays in-tree; use claude, codex, opencode, or pi for new agents until kimi is re-enabled.
audience: autonomous

### Grok session detect mints grok- aliases
summary: Grok tool shells that export GROK_AGENT are now detected as Grok and mint grok-* aliases instead of being mislabeled as codex-*.
setup: c2c install grok
clients: grok

### Managed Codex alias + stale-inbox delivery polish
summary: Managed Codex app-server sessions keep a stable advertised alias through first-turn whoami/banner, and idle or >2-minute stale inbox mail is still delivered via the app-server while PostToolHook remains active.
setup: c2c new codex
clients: codex
audience: autonomous

### Self-update follows HTTP redirects
summary: `c2c self-update` follows HTTP redirects (including 302), so upgrades from older installs no longer fail mid-download.
setup: c2c self-update
audience: all
