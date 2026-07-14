# B186 RESULT — install-time wake.toml

**Branch:** `fix/bl-b186`  
**Decision:** **REMOVE** auto-seed of `.c2c/schedules/<alias>/wake.toml` on
`c2c install` / `c2c init` (prefer-remove path from bug). Keep opt-in
`c2c schedule set` / MCP `schedule_set` and managed native heartbeat.

## Investigation

### What install wrote
- `C2c_setup.ensure_default_wake_schedule` wrote
  `.c2c/schedules/<alias>/wake.toml` with `interval_s = 246` (4.1m),
  idle-gated, message `wake — poll inbox, advance work`.
- Called from:
  - `do_install_client` after every known client setup (not Claude-only)
  - CLI-only `c2c init` path
- Manifest always recorded a schedule artifact path.

### Why it “didn’t work”
Schedule files only fire when a timer is active:

| Path | Timer |
|------|--------|
| Managed `c2c start` | `C2C_MCP_SCHEDULE_TIMER=1` on MCP child; or parent schedule watcher fallback |
| Raw MCP (Claude/Codex/…) | **Not** set in install MCP env → **dead** `wake.toml` |
| Explicit opt-in | `C2C_MCP_SCHEDULE_TIMER=1` (runbook Option 0b) |

So the common path (`c2c install claude` + raw Claude Code) left a schedule
file that never fired. Perception “only Claude does it” tracks the most
common install surface, not the code (all known clients got the seed).

### Double-wake on managed
Managed start already starts `builtin_managed_heartbeat` (~240s) via a
thread. Install’s `wake.toml` (~246s) also fired via the MCP schedule timer
→ near-duplicate self-DMs when both were present.

### Role / research corroboration
`.collab/research/2026-06-13-role-decoupling` already flagged
`ensure_default_wake_schedule` as forced autonomous-agent posture for solo
installs.

## Provider cache research (for intervals if re-adding)

| Provider / client | Cache window | Implication for heartbeat |
|-------------------|--------------|---------------------------|
| **Anthropic / Claude** | Default **5-minute** ephemeral TTL; optional **1-hour** TTL at ~2× cache-write cost | ~4.1m (246s) stays correct under default 5m |
| **OpenAI GPT-5.6+** | `prompt_cache_options.ttl` only supports **`30m`** (also default minimum lifetime); older in-memory retention often **5–10m** (up to 1h off-peak); extended retention up to 24h on older model families | Prefer ~25–28m for GPT-5.6 cache keepalive; 4m is wasteful under 30m TTL |
| **Gemini** | Explicit context cache default **1h** (custom TTL); implicit caching TTL undocumented/short | Prefer longer ticks if used only for cache; product default still ~4m for work ticks is fine |
| **Other (Kimi, Grok, OpenCode multi-model)** | No strong public “must tick under X” for c2c’s default models | Keep work-tick defaults conservative; document cache-aware `schedule set` intervals in runbook |

Sources: Anthropic prompt-caching docs; OpenAI developers prompt-caching guide
(GPT-5.6 `ttl: 30m`); Gemini/Vertex context-caching docs (1h default explicit).

## Change made

1. **Removed** `ensure_default_wake_schedule` and install/init call sites.
2. **Removed** automatic schedule artifact from install manifests.
3. Updated Claude managed onboarding preamble (B011/B186): native wake, no
   Monitor, no install-seed claim.
4. Updated role templates / role-designer / Cairn-Vigil / agent-wake-setup /
   client-delivery docs / changelog.
5. Tests: preamble + role template assertions.

### Intentionally kept
- `c2c schedule set|list|rm` CLI + MCP tools
- MCP schedule timer + `c2c start` watcher fallback
- Role-heartbeat → schedule-dir persistence on managed start
- `builtin_managed_heartbeat` for managed sessions (~4.1m / 240s)

### Not done (out of scope for remove path)
- Per-client cache-aware **default** intervals on `builtin_managed_heartbeat`
  (documented in runbook; future improvement)
- Enabling `C2C_MCP_SCHEDULE_TIMER=1` in raw client MCP install env (would
  re-create always-on wake for solo installs — rejected with this decision)
- Migrating/deleting existing on-disk `wake.toml` files (user/operator data)

## Tests run
- `just build` — OK
- `test_c2c_start` — 197 tests OK (includes preamble B186)
- `test_role_templates` — 6 tests OK

## Review tools
- `pirfl` / `review-and-fix` (gpt55) not available on this host PATH.
  Self-review performed against CLAUDE.md, install path, and schedule fire
  path; residual risk: pre-existing `wake.toml` files still fire under
  managed schedule timer (operator can `c2c schedule rm wake`).

## SHAs
Recorded after commit in the final report.
