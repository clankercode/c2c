# Grok Bot fleet identity research (B345)

Research date: 2026-10-04T06:15:54Z. Question: what identity signals exist for
Cursor "Grok Bot" cloud agents, so c2c relay support can name, reach, and wake
Bot sessions? Every claim below cites the source that owns it; secondary
write-ups are flagged as such. Leads that did NOT verify are marked UNVERIFIED
rather than dropped, so the next session does not re-chase them.

## 0. Verdict for B345 (read this first)

- A Grok Bot is **not a local process**. It runs on a Cursor-hosted per-user
  cloud computer (Firecracker microVM); the desktop app is a client to it.
  There is **no hook, plugin, extension, session store, or local OTLP surface**
  to attach c2c to — two independent implementers (Beacon, websentry) reached
  this conclusion from opposite directions (see §3).
- c2c relay support therefore cannot be hook-shaped. The viable shapes are:
  (a) an **unofficial gateway-API client** on the operator's machine reusing the
  operator's Cursor access token (two working open-source precedents, §2.1);
  (b) a **Bot-side skill + routine** that polls a relay endpoint from the cloud
  computer's own terminal (network default is allow-all, §4 — but in-Bot
  outbound to arbitrary hosts is still unverified live); (c) **Enterprise OTLP
  export** for observability only (no prompt text, no tool args, §2.3).
- Stable Bot identity = the **gateway agent id** (survives renames) or, in
  export telemetry, **`cursor.conversation.id`**. User-chosen Bot names are
  display names, not keys. No `grokbot-<name>-<hex>` session format and no
  `forge`/`wrench` fleet names were found anywhere — UNVERIFIED, treat the
  coordinator's parentheticals as speculation (§1.4).

## 1. What a Grok Bot IS (vs Grok Build vs Cursor Agent)

### 1.1 Product shape

- Grok Bot = xAI/SpaceXAI "always-on AI teammates" product, launched in beta
  **2026-08-11**, days before SpaceX completed the **~$60B all-stock Cursor
  (Anysphere) acquisition on 2026-08-14**.
  - Launch + acquisition context: [9to5Mac](https://9to5mac.com/2026/08/14/spacex-lands-deal-to-likely-purchase-claude-code-and-openai-codex-competitor/),
    [earlyterms.com term page](https://earlyterms.com/term/grok-bot/) (secondary),
    [DeepLearning.AI The Batch](https://www.deeplearning.ai/the-batch/groks-cursor-alliance-pays-off) (secondary).
- Each Bot is a durable named teammate (name, job, compounding context/memory)
  working on a **persistent per-user cloud computer** with browser, filesystem,
  terminal; work continues with the laptop closed; reachable from desktop and
  mobile apps. Official:
  [docs.x.ai/grok-bot/overview](https://docs.x.ai/grok-bot/overview),
  [docs.x.ai/grok-bot/get-started](https://docs.x.ai/grok-bot/get-started).
- **One computer per user, shared by all of that user's Bots** (files, browser
  sessions, app logins shared; memory/conversations per-Bot; each Bot gets its
  own screen; one computer-use task per Bot at a time). Between users isolation
  is strict (dedicated Firecracker microVM each — kernel, memory, vdev).
  Official: [overview](https://docs.x.ai/grok-bot/overview),
  [security-faq](https://docs.x.ai/grok-bot/security-faq).
- Bots coordinate: parallel work, Bot-to-Bot messages, group chats, task
  ownership handoff; group Bots exist as a first-class record
  (`isGroup` + `memberIds`). Official
  [overview](https://docs.x.ai/grok-bot/overview); group fields in
  [gbot-pipeline gateway.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/gateway.mjs).
- Auth/data plane is **Cursor's, not xAI's**: "Grok Bot uses your Cursor
  account"; "uses Cursor authentication and account data settings"; requires
  cloud data storage; Legacy Privacy Mode unsupported; SSO via org flow.
  Official: [get-started](https://docs.x.ai/grok-bot/get-started) (fetched
  verbatim); auth sentence quoted at
  [digitalapplied](https://www.digitalapplied.com/blog/grok-bot-ai-teammates-launch-cloud-computer-2026) (secondary).

### 1.2 Not Grok Build, not Cursor Agent, not @grok

- **Grok Build** = xAI's terminal coding agent (CLI/TUI, runs on the operator's
  endpoint under the operator's account). Beacon hooks it under harness `grok`
  and **deliberately refuses** to fold `grok` / `grok-4` / `grok-4.6` /
  `grok-code-fast-1` into `grok_bot` (equality against a closed set, not
  Contains): merging them "would file cloud-computer shell commands under a
  local CLI". Primary (source code + commit message):
  [agent-beacon #461 patch](https://github.com/asymptote-labs/agent-beacon/commit/4eed6f97c784050e10d171ff35ff28e5271d0744.patch).
- **Cursor Cloud Agents** = the separate `api.cursor.com/v1/agents` API / IDE
  background agents. A Bot can **delegate coding tasks to them** (team-wide
  admin toggle "Cloud Agents", on by default), and Grok-launched agents appear
  on [cursor.com/agents](https://cursor.com/agents) behind the **Source → Grok
  Bot** filter (Cursor staff @Colin, 2026-08-28, forum post 11).
  Secondary-with-vendor-statement:
  [forum 169754 via awesome-grok-bot](https://github.com/ronglecat/awesome-grok-bot),
  [firstmate research note](https://github.com/matteoantoci/firstmate/blob/HEAD/research/grok-bot-context-window.md),
  [botskills VERIFIED-FACTS 2026-09-23](https://github.com/pramoddutta/botskills/blob/HEAD/docs/seo/VERIFIED-FACTS-2026-09-23.md).
- Internal codename for the Grok Bot stack is **"Sand"**: bundle id
  `com.anysphere.sand`, `x-cursor-client-type: sand` header, `sand-secrets.json`
  session file, `DashboardService/GetSandUsageStatus` usage RPC ("Sand"
  internally = the weekly allowance lane).
  Primary: [websentry commit](https://github.com/websentry-ai/coding-discovery-tool/commit/033872e398adc1baea72d4d2d3e2f8efb3bd70f6.patch),
  [grokbot.py](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/scripts/grokbot.py),
  [ItsJazii/pane #228](https://github.com/ItsJazii/pane/pull/228),
  [quotabar commit](https://github.com/gentpan/quotabar/commit/04b49969091ca47330c293615c22c06552cf74b4).

### 1.3 How Bots are spawned and named

- Operator path (official): desktop app → Meet-a-teammate suggestion or **New →
  Create new Bot** with a **short name + one job + description**
  (worked example: Name "Piper", Job "Product performance").
  [get-started](https://docs.x.ai/grok-bot/get-started).
- API path (unofficial, working code): `createAgent` with
  `{name, description, title, origin: "user", isKickstartRequested}`; `#Name`
  chat routing; names with spaces addressable via hyphen fold (`#fh-cto`).
  [gateway.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/gateway.mjs),
  [SKILL.md](https://raw.githubusercontent.com/saivarun3407/gbot-pipeline/HEAD/plugins/grok-bot/skills/grok-bot/SKILL.md).
- Naming semantics: **names are mutable display labels; the server-side id is
  the stable key** ("Put the id in config.jsonc rather than the name — ids
  survive renaming a bot in the app").
  [mastermilkyshake/iagents](https://github.com/mastermilkyshake/iagents)
  (third-party client README).
- Scale anecdote (secondary, unverified by vendor): SpaceXAI engineer Lingxi
  Li's X essay (2026-08-31/09-01) describes **five specialized Bots
  coordinating 200+ Cursor cloud agents**, backed by a Notion database and an
  ops-bot playbook.
  [explainx.ai summary](https://www.explainx.ai/blog/grok-bot-engineering-org-200-cloud-agents-lingxi-li-2026)
  (secondary write-up of a primary X essay; the essay itself was not pulled).

### 1.4 UNVERIFIED leads (do not build on these)

- **`forge` / `wrench` fleet names**: no source found. No fleet-name concept
  appears in official docs, Beacon, websentry, gbot-pipeline, grok-bot-skill,
  or forum threads searched. Closest real concepts: user-chosen Bot names,
  group chats / group Bots, and third-party role tags (`[GB-<NAME>]` in
  [ai-fleet-coordinator](https://github.com/jaywedgeworth22/ai-fleet-coordinator/blob/HEAD/.grok/skills/session-start/SKILL.md),
  which is one user's overlay, not vendor vocabulary).
- **`grokbot-<name>-<hex>` session-id format**: no source found. Real session
  keys observed: `cursor.conversation.id` (OTLP export), gateway agent `id`,
  `cursor.grok_bot.tool_call.id` (tool calls). See §2.

## 2. Identity signals

### 2.1 Host-side (operator machine) — richest surface

Local files (all primary: working client source):

| Signal | Path / value | Source |
|---|---|---|
| State dir (cross-platform tell) | `~/.grokbot/` — local-exec helper log lives here | [Beacon PR #463 patch](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/463.patch) |
| Device config | `~/.grokbot/settings.json` — local-execution permission, egress routing, MCP server ids | [websentry commit](https://github.com/websentry-ai/coding-discovery-tool/commit/033872e398adc1baea72d4d2d3e2f8efb3bd70f6.patch) |
| Local-exec credential + connection files | beside settings.json; exact filenames not captured (commit puts them in a never-read set) | same |
| App session dir macOS | `~/Library/Application Support/Grok Bot/` | [paths.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/paths.mjs) |
| App session dir Linux | `$XDG_CONFIG_HOME/Grok Bot/` else `~/.config/Grok Bot/` | same |
| App session dir Windows | `%APPDATA%/Grok Bot` | same |
| Gateway descriptor (encrypted) | `<appdir>/gateway-descriptor.json` → `{baseUrl, token, headers}` | [session_posix.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session_posix.mjs) |
| Access token (encrypted) | `<appdir>/sand-secrets.json`, key `cursor-access-token`, `scoped:v1:<id>:<b64 v10 blob>` | [grokbot.py](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/scripts/grokbot.py), [session_posix.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session_posix.mjs) |
| Keychain entry | macOS Keychain `Grok Bot Safe Storage` (account `Grok Bot Key`); Linux libsecret (`secret-tool lookup xdg:schema chrome_libsecret_os_crypt_password_v2 application "Grok Bot"`); AES-128-CBC, PBKDF2-SHA1 `saltysalt` 1003 iters; Windows DPAPI via `win_dpapi.ps1` | [grokbot.py](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/scripts/grokbot.py), [session_posix.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session_posix.mjs) |
| App bundle | `/Applications/Grok Bot.app` (or `~/Applications`), version from `Info.plist` | [websentry commit](https://github.com/websentry-ai/coding-discovery-tool/commit/033872e398adc1baea72d4d2d3e2f8efb3bd70f6.patch) |
| Linux install location | NONE stable — .deb/.rpm/AppImage share no path; Beacon detects Linux by `~/.grokbot` only | [Beacon PR #463 patch](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/463.patch) |

Env vars (unofficial-client convention, NOT vendor — no vendor-issued `GROK_*`
/ `CURSOR_*` vars were found in any official doc):

- `CURSOR_ACCESS_TOKEN` (primary) / `GROK_BOT_ACCESS_TOKEN` / `SAND_ACCESS_TOKEN`;
  `GROK_BOT_GATEWAY_TOKEN|URL|HEADERS`, `SAND_HOST_GATEWAY_TOKEN|URL`,
  `SAND_GATEWAY_TOKEN`; `SAND_BACKEND_URL` / `CURSOR_API_BASE_URL` (default
  `https://api2.cursor.sh`); `SAND_BOX_NAMESPACE` (default `prod`);
  `SAND_CLIENT_VERSION`.
  Primary: [session.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session.mjs).

API identity flow (unofficial, two independent implementations agree):

1. `POST https://api2.cursor.sh/aiserver.v1.GrokBotService/EnsureSandBox`
   (Connect-RPC: `connect-protocol-version: 1`,
   `x-cursor-client-type: sand`, `x-sand-box-namespace: prod`,
   `x-ghost-mode: false`, `Authorization: Bearer <CURSOR_ACCESS_TOKEN>`)
   → `{gatewayUrl, gatewayToken, (anyrun network token → header
   `x-anyrun-network-token`), cluster, podId}`.
   "Cursor dashboard API keys do not work; use a Cursor access token."
2. Gateway calls: `POST {gatewayUrl}/api/<method>` with
   `Authorization: Bearer <gatewayToken>`; methods include `listAgents`,
   `createAgent`, chat/send/transcript/update/pull equivalents.
3. Allowed gateway hosts: `*.cursor.sh`, `cursorvm.com`, `*.cursorvm.com`,
   `localhost`/`127.0.0.1` (http allowed only for local).
  Primary: [session.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session.mjs),
  [gateway.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/gateway.mjs),
  [grokbot.py](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/scripts/grokbot.py),
  [paths.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/paths.mjs).

### 2.2 Inside the Bot session (on the cloud computer) — thin surface

- Login user appears to be **`box`**: third-party skill paths reference
  `/home/box/agent-data/workflows/<skill-name>` (skill install target) and
  search `~/.grok/skills/`.
  [rickgorman/add-new-grok-bot-skill SKILL.md](https://raw.githubusercontent.com/rickgorman/agent-files/HEAD/.claude/skills/add-new-grok-bot-skill/SKILL.md)
  (third-party quoting live paths — weakest citation in this file; needs
  live confirmation).
- Shared computer root **`/workspace`** (pull example
  `/workspace/flux-hydration`; "The shared cloud computer is at `/workspace`").
  [grok-bot SKILL.md](https://raw.githubusercontent.com/saivarun3407/gbot-pipeline/HEAD/plugins/grok-bot/skills/grok-bot/SKILL.md),
  [knocklabs connect-grok-bot.md](https://github.com/knocklabs/skills/blob/HEAD/skills/knock-setup/rules/connect-grok-bot.md) (third-party).
- **No vendor `GROK_*` / `CURSOR_*` env vars, no `~/.grok` vs `~/.cursor`
  authority, no `active_sessions` file, and no tool-call-ID env inside the Bot
  session were found in any source.** The `cursor.grok_bot.tool_call.id` lead
  resolves to an **OTLP attribute**, not an env var (next section).

### 2.3 Server-side OTLP export keys (Beacon PRs 1/4, 2/4, 4/4) — primary

Cursor Enterprise server-side OpenTelemetry Export (Action Recording on) is
the Bot's only telemetry channel: OTLP/HTTP logs+metrics with
**`cursor.surface=grok_bot`** on the resource and the event name in the log
body. Beacon maps it in
[`cursor_grokbot.go`](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/462.patch)
(fixture "follows Cursor's published wire reference field by field"):

| Key | Meaning |
|---|---|
| `cursor.grok_bot.tool_call.id` | MCP/computer-use session tool-call id → promoted to `gen_ai.tool.call.id` on every capture path (the coordinator's lead, CONFIRMED as OTLP attr) |
| `cursor.conversation.id` | **the session id** |
| `cursor.user.id` | replaces collector process user (collector's uid "has nothing to do with whoever drove the Bot") |
| `cursor.token.type`, `cursor.model.name` | metric aliases folded into `gen_ai.usage` |
| body `grok_bot_shell_command` | → `command.executed` (secret-scrubbed `command.command`); or `approval.denied` w/ Cursor's shell-policy decision+reason when `shell.allowed=false`; origin `local` if Cursor reports the command targeted the member's own machine, else `cloud` |
| MCP tool-call bodies | → `mcp.tool_invoked` / `tool.failed` with server+tool |
| browser navigation | → `tool.invoked`, URL host on `server.address` |
| computer-use sessions | → `tool.invoked` |
| body `api_request` | → `session.activity`, 4 request token counts into `gen_ai.usage` |

Export contract limits (load-bearing for B345 observability hopes): **no prompt
text, no tool arguments, no file activity, no approval requests**.
Patches:
[(1/4) #461 identity](https://github.com/asymptote-labs/agent-beacon/commit/4eed6f97c784050e10d171ff35ff28e5271d0744.patch),
[(2/4) #462 exporter](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/462.patch),
[(4/4) #464 docs](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/464.patch).

## 3. Hooks / skills / plugin surfaces for c2c attach

- **No local hooks of any kind.** Beacon #463 (primary, shipped code): the app
  "exposes no hook, plugin, extension, session store, or local OTLP export, so
  there is nothing for Beacon to install and detection is the whole of what the
  endpoint can do"; doctor reports presence as informational
  (`cloud_export_only`), never a fixable warning. Detection: `~/.grokbot`
  (all platforms) + best-effort macOS bundle / Windows Programs paths.
  [PR #463 patch](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/463.patch).
- **No session-start/end events, no hook payloads, no skill dirs on the
  endpoint.** websentry independently confirmed the negative from the other
  side: adding an MCP server + a private skill in the app "wrote neither to
  any readable file on the device", so they ship config extraction
  (`~/.grokbot/settings.json`) but **no MCP or skills extractor**.
  [websentry commit](https://github.com/websentry-ai/coding-discovery-tool/commit/033872e398adc1baea72d4d2d3e2f8efb3bd70f6.patch).
- **Product-level skills DO exist, but they live on the cloud computer.**
  Official mechanics ([skills-and-routines](https://docs.x.ai/grok-bot/skills-routines-and-automations)):
  skills = reusable instruction sets, one private library shared by all of a
  user's Bots, referenced with `/` in the composer (`@` for Bots/groups/
  routines/connectors), managed at Marketplace → Your plugins; teachable by
  demonstration (≤10 min, no mic); routines = scheduled/event-triggered runs
  (Slack/GitHub events via Cursor account integrations) with Test-run.
- Skill install surface (third-party, needs live confirmation):
  `SKILL.md`-shaped folders installed to `/home/box/agent-data/workflows/`
  and `~/.grok/skills/`.
  [rickgorman SKILL.md](https://raw.githubusercontent.com/rickgorman/agent-files/HEAD/.claude/skills/add-new-grok-bot-skill/SKILL.md).
- MCP attach (third-party report of vendor behavior): tell a Bot in chat
  "Add this MCP server: \<url\>", tools appear next message, server shows under
  Settings → Plugins → Yours.
  [muse-brain design.md](https://github.com/yahavf6/muse-brain/blob/HEAD/docs/design.md)
  (secondary).
- Practical c2c attach points, ranked: (1) unofficial gateway API client
  (precedents: [gbot-pipeline](https://raw.githubusercontent.com/saivarun3407/gbot-pipeline/HEAD/plugins/grok-bot/skills/grok-bot/SKILL.md)
  MCP tools `grok_bot_{list,chat,send,transcript,create,update,pull,doctor}`,
  [grok-bot-skill](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/README.md)
  `status|list|chat|send|create|update|transcript` CLI);
  (2) a Bot-side skill + scheduled routine that polls a c2c relay endpoint
  from the Agent Computer terminal (file bridge precedent: `agent-bridge.mjs`
  packs `/workspace` dirs to tarballs over cloudflared in
  [gbot-pipeline](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/agent-bridge.mjs));
  (3) Enterprise OTLP export for presence/activity only.

## 4. Billing/dashboard + Bot↔host boundaries

### 4.1 Billing (Cursor forum 170951 — vendor statements via staff "Mohit", Sept 2026)

Primary thread (user post summarizing staff statements; staff posts not
individually pulled):
[forum.cursor.com/t/170951](https://forum.cursor.com/t/can-cursor-clarify-exactly-which-grok-bot-usage-counts-against-the-weekly-pool-vs-cursor-models-other-models/170951).

- Normal Bot conversations → **separate Grok Bot weekly pool** (internal name
  "Sand"; dashboard meter "Grok Bot — Weekly usage" via
  `DashboardService/GetSandUsageStatus`:
  [pane #228](https://github.com/ItsJazii/pane/pull/228)).
- Routines/automations + browser actions / cloud-agent work → **Cursor plan /
  Other Models**; can exhaust Other Models and block Claude/GPT while weekly
  pool still has room (Mohit, Sept 3, per OP).
- `grok-bot-*` rows under "Cursor Models" are **display-only** (dashboard
  groups by serving model, not product): no allowance consumption, no rate
  limiting (Mohit, Sept 7, per OP).
- **Cloud agents launched from Grok Bot DO count toward the Cursor plan**
  (Mohit, quoted in OP).
- Open/unresolved in-thread: what exactly `grok-bot-automation` and
  `grok-bot-cua` rows charge (weekly pool vs plan vs both — possibly
  orchestration on weekly + execution on plan). Do not quote a resolution;
  the thread asks and this research did not find the answer.
- Admin surface: Grok Bot page at `cursor.com/dashboard/bot` (enable switch,
  group access, Cloud Agents toggle, Team Rules, local-execution cap,
  connector policy); **no Grok Bot-specific spend cap** (account-level
  on-demand controls apply; usage on dashboard usage page).
  Secondary reporting vendor docs:
  [botskills VERIFIED-FACTS](https://github.com/pramoddutta/botskills/blob/HEAD/docs/seo/VERIFIED-FACTS-2026-09-23.md),
  [cellcog pricing](https://cellcog.ai/blog/grok-bot-pricing/),
  [eesel pricing](https://www.eesel.ai/blog/grok-bot-pricing).

### 4.2 Bot↔host boundaries (official security-faq, fetched verbatim)

All from [docs.x.ai/grok-bot/security-faq](https://docs.x.ai/grok-bot/security-faq):

- Compute: per-user Firecracker microVM; intra-user fully shared (any login/
  file visible to every Bot of that user — "All Bots share one cloud
  computer. Names are not a security boundary", independently warned in
  [gbot-pipeline SKILL.md](https://raw.githubusercontent.com/saivarun3407/gbot-pipeline/HEAD/plugins/grok-bot/skills/grok-bot/SKILL.md)).
  Cross-workload isolation = separate Cursor user.
- Identity: **a Bot has no identity of its own**, never more access than the
  signed-in member; connector tokens stay on Cursor backend; login/2FA/payment
  steps hand to the member via Agent Computer takeover.
- Network: default **allow-all** (no policy without Enterprise **Network
  Controls** destination allowlist); plugin block ≠ website block; egress via
  **shared static ranges** (datacenter IPs; some sites block them; no
  dedicated IPs); member can route computer web traffic through their desktop
  (local egress; Enterprise-gated team-wide + per-group widen-only); private
  networks via Team Setup client:
  linked [private-networks](https://docs.x.ai/grok-bot/private-networks) page (not pulled).
- Hostnames: backend `api2.cursor.sh`; computer link `*.cursorvm.com` +
  nested `*.*.cursorvm.com` (must bypass TLS inspection; Zscaler-style
  gateways break computer setup while chat keeps working).
- Local-computer execution is a separate opt-in capability with a team cap,
  configured per-desktop/shared-computer, NOT per-Bot (settings docs via
  [lokma research](https://github.com/raksix/lokma/blob/HEAD/Docs/raw/42-grok-bots-ham-arastirma.md),
  secondary).

## 5. Source index (primary-first)

Vendor/official: [overview](https://docs.x.ai/grok-bot/overview),
[get-started](https://docs.x.ai/grok-bot/get-started),
[security-faq](https://docs.x.ai/grok-bot/security-faq),
[skills-routines-and-automations](https://docs.x.ai/grok-bot/skills-routines-and-automations),
[forum 170951 (billing)](https://forum.cursor.com/t/can-cursor-clarify-exactly-which-grok-bot-usage-counts-against-the-weekly-pool-vs-cursor-models-other-models/170951).
Source code (primary): [Beacon #461](https://github.com/asymptote-labs/agent-beacon/commit/4eed6f97c784050e10d171ff35ff28e5271d0744.patch),
[#462](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/462.patch),
[#463](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/463.patch),
[#464](https://patch-diff.githubusercontent.com/raw/Asymptote-Labs/agent-beacon/pull/464.patch),
[websentry grokbot commit](https://github.com/websentry-ai/coding-discovery-tool/commit/033872e398adc1baea72d4d2d3e2f8efb3bd70f6.patch),
[gbot-pipeline session.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session.mjs) /
[gateway.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/gateway.mjs) /
[paths.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/paths.mjs) /
[session_posix.mjs](https://raw.githubusercontent.com/saivarun3407/Gbot-pipeline/main/plugins/grok-bot/scripts/lib/session_posix.mjs),
[grokbot.py](https://raw.githubusercontent.com/adamanz/grok-bot-skill/HEAD/scripts/grokbot.py).
Secondary: [explainx.ai essay summary](https://www.explainx.ai/blog/grok-bot-engineering-org-200-cloud-agents-lingxi-li-2026),
[9to5Mac acquisition](https://9to5mac.com/2026/08/14/spacex-lands-deal-to-likely-purchase-claude-code-and-openai-codex-competitor/),
[lokma research doc](https://github.com/raksix/lokma/blob/HEAD/Docs/raw/42-grok-bots-ham-arastirma.md),
[firstmate note](https://github.com/matteoantoci/firstmate/blob/HEAD/research/grok-bot-context-window.md).
