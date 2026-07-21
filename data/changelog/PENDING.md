# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the agent-facing
changelog auto-show (`merged_entries`) and remote-cache fetch both read
CHANGELOG.md, and a premature version heading confuses "what's new since last
binary" surfaces (observed 2026-07-13 during B140). Note B268's passive
`update_available` / `latest_known_newer` read the *remote* cache only, not
the embedded file — still keep unreleased headings out of CHANGELOG.md.

### Passive "newer release available" nudge (B268)
summary: When the local changelog cache already knows a release newer than this binary, `c2c doctor`, `c2c health` / `server-info` (JSON fields `latest_known_version` + `update_available`), SessionStart (one line, once per newer release), and `c2c --version` (optional trailing line) surface it. Relay version-behind-latest is informational in doctor/health. Cache-only — no synchronous network on hot paths; offline/empty cache stays silent.
audience: all
setup: c2c self-update

### `c2c install git-hook` is retired (breaking)
summary: The `git-hook` install/uninstall component is gone. `c2c install git-hook` is now an unknown command and `c2c uninstall git-hook` reports an unknown component (with the remaining component list). The guard script it installed was inert in practice — the checkout's `core.hooksPath` points at the user-global hooks dir, not `.git/hooks`, so git never consulted it — and its name collided confusingly with the separate repo-local dev hooks (`scripts/git-hooks/` + `just install-git-hooks`, which are unaffected). The `git-shim` component is unchanged (kept for its active safety guards). Existing installs are no longer swept by `c2c uninstall all`; remove `.git/hooks/pre-commit` by hand if one is present.
audience: all

### Client install is opt-in by default; MCP is now behind --with-mcp (B254, B255, B256)
summary: `c2c install <client>` still writes hooks, the identity skill, the OpenCode plugin, and the CLI by default, but it no longer writes an MCP server config unless you pass --with-mcp. `c2c install all` is binary-only unless you pass --with-clients. Managed `c2c start codex` no longer needs the [mcp_servers.c2c] block in your Codex config — the app-server/CLI path carries delivery. Delivery you already rely on is unchanged; you only opt in to the MCP tool surface when you actually want it.
setup: c2c install claude --with-mcp
audience: all

### `c2c install` / `c2c start` warn when you must poll manually (#37)
summary: When a client cannot be woken automatically at idle (no plugin, app-server, REST, or armed monitor), install and start now warn that inbound mail will not reach you until you poll — so you can arm a `c2c monitor` or call poll_inbox instead of silently missing messages.
audience: all

### `c2c list` defaults to the current repo/dir (#74)
summary: Plain `c2c list` on the default broker now shows only peers registered from the current repository/directory, not every peer on the machine. Pass --cross-repo (or use the sessions broker) to see everyone. The scope filter applies only to the default broker.
setup: c2c list --cross-repo
audience: all

### New `c2c gc-inboxes`: reclaim orphaned inboxes (#53)
summary: `c2c gc-inboxes` safely reclaims broker inboxes that have no live registration row (archive-then-remove) while preserving managed sessions — a targeted cleanup for dead peers instead of a blunt sweep that can strand live sessions.
setup: c2c gc-inboxes
audience: all

### Seamless upgrades for managed sessions (I010–I013)
summary: After you rebuild or reinstall c2c, managed sessions still on the old binary are detected as stale and rolled onto the new one without a manual kill: `c2c monitor --self-stale-exit` exits 0 with an exact relaunch command on a binary upgrade, `c2c restart-sidecar <name> <deliver|poker>` restarts a session's delivery sidecar without touching the inner client, and restart-stale uses a fail-closed idle policy so a busy turn is never interrupted.
setup: c2c restart-stale
audience: all

### Antigravity (agy) is a first-class managed client with automated idle wake (#61, #65, #66, #69, #78)
summary: `c2c install agy` and `c2c start agy` now register from agy's own workspace (so peers in that repo can see you), keep their discovered env across turns, and wake an idle agy TUI automatically via agy's agentapi — no human Enter and no throwaway headless conversation. Inbound mail is delivered as DATA (never an approval). An unmanaged agy launched in a repo now registers into that repo's broker instead of the global default.
setup: c2c install agy
clients: agy
audience: all

### Relay stays resident under load (B219)
summary: The hosted relay was intermittently dying under sustained multi-peer load with a native SIGSEGV in sqlite3_finalize — a GC-finalizer use-after-free from opening a SQLite connection per request and leaving statements unfinalized. It now uses a single persistent connection with every statement finalized explicitly, so it stays up. No client action needed; delivery via relay.c2c.im is more reliable.
audience: all
