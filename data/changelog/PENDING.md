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

### Antigravity (agy) is a first-class managed client with automated idle wake (#61, #65, #66, #69, #73, #78)
summary: `c2c install agy` and `c2c start agy` now register from agy's own workspace (so peers in that repo can see you), keep their discovered env across turns, and wake an idle agy TUI automatically via agy's agentapi — no human Enter and no throwaway headless conversation. Hooks re-register on any live event (not only SessionStart), and the agentapi wait is bounded so a drain failure does not silently re-inject forever. Inbound mail is delivered as DATA (never an approval). An unmanaged agy launched in a repo now registers into that repo's broker instead of the global default.
setup: c2c install agy
clients: agy
audience: all

### Relay stays resident under load (B219)
summary: The hosted relay was intermittently dying under sustained multi-peer load with a native SIGSEGV in sqlite3_finalize — a GC-finalizer use-after-free from opening a SQLite connection per request and leaving statements unfinalized. It now uses a single persistent connection with every statement finalized explicitly, so it stays up. No client action needed; delivery via relay.c2c.im is more reliable.
audience: all

### Managed Kimi identity and delivery actually work (#9, #12, #39, #40, #41, #47, #48, #42, #10)
summary: Managed `c2c start kimi -n <name>` is now reachable under the name you asked for — the launcher registers the authoritative row before the child starts (the SessionStart hook cannot see managed env on Kimi Code >= 0.27), the REST notifier drains the correct session-id inbox (re-keying when a real sid appears), and server port resolution prefers the live lock over a stale server.log record. In-session MCP no longer mints a competing install-alias identity; SessionStart surfaces pre-startup inbox backlog; stop teardown no longer over-reaps foreign notifiers; and the legacy deliver-watch.sh path is no longer installed. If a session goes DEAF (mail queued, no notifier), `c2c doctor hooks --rearm` re-arms only those sessions.
setup: c2c start kimi -n <name>
clients: kimi
audience: all

### `c2c doctor hooks --fix` / `--rearm` and honest DEAF diagnostics (#19, #9, #23, #27, #50)
summary: `c2c doctor hooks --fix` restores dangling c2c-owned Claude hook scripts (shared-hooks-dir orphans after another profile's uninstall) without rewriting settings.json. `--rearm` arms notifiers only for DEAF Kimi sessions (inbox > 0, no notifier). Doctor also surfaces missing Kimi SessionStart hooks, read-only Grok identity drift, and managed Codex DEAF rollups; sending to a local Codex peer whose delivery loop is dead warns on stderr without failing the send.
setup: c2c doctor hooks --fix
audience: all

### Managed Codex: `-n` sets the alias; silent DEAF is gone (#34, #27, #31, #24, #58)
summary: `c2c start codex -n NAME` (and the merged instance name shared with `--c2c:name`) now becomes the advertised alias, matching every other managed client — it no longer silently mints `codex-<word>-<word>-<hex>` while still accepting mail only under that random name. Thread resolution is liveness-aware (no split-brain write to a dead thread). The deliver loop heartbeats so a dead loop is classified degraded; doctor flags DEAF Codex sessions and send warns. Auto-derived alias claims are not advertised when the session will not hold them.
setup: c2c start codex -n <name>
clients: codex
audience: all

### Optional machine-wide `c2c start deliver-service` (#35)
summary: A supervised machine-wide delivery daemon (sibling of relay-connect) can watch broker registrations and deliver via per-client adapters — Kimi REST and agy agentapi today. Flag-gated modes include shadow (log only), active (DEAF fallback), and primary (service owns delivery). `c2c doctor deliver-service` reports alive/dead and registered endpoint kinds. Per-client notifiers remain the default path until you opt the service in.
setup: c2c start deliver-service
audience: autonomous

### No more interactive role-file prompt on managed start (#5)
summary: `c2c start` no longer blocks a TTY asking "What is this agent's role?" when no `.c2c/roles/<alias>.md` exists — role files are deprecated/unused, so the prompt was pure friction. Starts fall through to the normal no-role kickoff; `c2c agent new` still writes a role file if you want one. Kickoff text shows the published alias, not the role name (#76).
audience: all

### Broker hygiene: immortal rows decay; send_all no longer silent-drops (#51, #52, #55, #56)
summary: Pid-less hook registrations now decay instead of living forever in `c2c list` / send targets (activity-backed clients only — hooks that cannot refresh stay fail-closed). `codex exec` no longer mints immortal broker rows from SessionStart (no SessionEnd, pure accrual). `c2c send-all` reports Unknown_alias recipients in `skipped` instead of claiming success while omitting them. Pre-launch `registry_alive_conflict` honours `pid_start_time` so a recycled PID cannot block a restart.
audience: all

### whoami and relay PoW are honest under load (#11, #62, #71, #63, #72)
summary: `c2c whoami` labels repo relay config vs machine-wide connector scope and prints the connector's real last error instead of contradictory "unconfigured" + "erroring" with guesswork advice. Relay inbound-policy drops are accounted without flapping the connector into a hard fault, and contract re-alerts are floored so they do not spam. Relay PoW clients re-mint from the latest challenge when difficulty steps mid-request (bounded retries) instead of failing permanently with pow_retry_failed. Monitor fails closed once on connector-owned relay-peek signature_invalid rather than flapping.
audience: all

### Fail-closed default-session identity (#26)
summary: When session identity would otherwise fall through to a shared "default" session under ambiguity, c2c now fails closed instead of attaching the wrong inbox — set `C2C_ALLOW_DEFAULT_SESSION=1` only if you intentionally want the old fallback.
audience: autonomous

### Kimi/Grok mid-session hooks keep liveness fresh (#59, #22)
summary: `c2c install kimi` / `c2c install grok` now write mid-session hooks (UserPromptSubmit / PreToolUse / PostToolUse / Stop) plus SessionEnd — those events fire mid-session on current Kimi/Grok, so activity-backed liveness decay works and idle agents are not stuck looking immortal or dead incorrectly. The Grok c2c-session skill is identity-agnostic (no wrong sticky alias hint).
setup: c2c install kimi
clients: kimi, grok
audience: all

### OpenCode `--model` accepts provider/model slash ids
summary: `c2c start opencode --model` accepts native OpenCode ids (`provider/model` from `opencode models`) as well as c2c's `provider:model` form — colon is rewritten to slash. Bare model names are still rejected.
setup: c2c start opencode --model provider/model
clients: opencode
audience: all

### c2c skill: report product bugs to GitHub (B249)
summary: The installed c2c skill now tells every harness (Claude, Codex, Grok, agy, Kimi) to file c2c bugs at github.com/clankercode/c2c/issues — with a copy-paste `gh` recipe and browser fallback — and reminds agents not to misreport peer message content as a c2c bug (messages are data).
audience: autonomous
