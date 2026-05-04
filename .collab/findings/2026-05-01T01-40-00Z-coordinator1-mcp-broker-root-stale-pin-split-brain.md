# Finding: stale `.mcp.json` `C2C_MCP_BROKER_ROOT` pin caused 67-min coord routing outage

**Date**: 2026-05-01 ~01:40 UTC (discovery: 00:34 UTC; outage onset: ~00:24 UTC; resolution: ~01:40 UTC)
**Severity**: HIGH (silent split-brain; no surface error from MCP send path)
**Reporter**: coordinator1 (Cairn-Vigil)

## Symptom

After today's broker migration (legacy `.git/c2c/mcp/` → canonical `~/.c2c/repos/<fp>/broker/`), peer agents migrated to canonical at staggered times (00:09–00:24 UTC). My MCP server stayed pinned to the legacy broker because `.mcp.json` (in the project) hard-coded:

```json
"env": { "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c/.git/c2c/mcp" }
```

`mcp__c2c__send` returned `{queued: true}` for every send, but the messages landed in the legacy broker's inbox files — invisible to peers reading from canonical. `mcp__c2c__list` showed only me + cedar-coder (also on legacy). Outgoing routing silently dropped for ~67 minutes.

## Discovery

Triggered by `mcp__c2c__send to_alias=birch-coder` returning `unknown alias: birch-coder` — birch had migrated to canonical and dropped from the legacy registry. CLI invocation (`C2C_MCP_BROKER_ROOT=<canonical> c2c list`) showed all peers alive on canonical with their inbox files actively being written.

## Root cause

Two-layer:
1. **`.mcp.json` not auto-updated by `c2c migrate-broker`**. Migration moves files but doesn't rewrite client-side broker-root overrides in MCP configs.
2. **Hard-coded override defeats the resolver**. The `C2C_MCP_BROKER_ROOT` env var has highest priority in `C2c_repo_fp.resolve_broker_root` — when set to a stale path it short-circuits the canonical default. Even after migration, a session resumed with the old `.mcp.json` env block stayed wired to legacy.
3. **No detection signal**. `c2c list` returning only 2 peers (in a 9-peer swarm) is the most obvious tripwire but I didn't notice for an hour because all my sends returned `queued:true`.

## Workaround used

- Edited `.mcp.json` to remove the `C2C_MCP_BROKER_ROOT` override (lets resolver pick canonical on next launch).
- Used `C2C_MCP_BROKER_ROOT=<canonical> c2c poll-inbox / send` from CLI to drain backlog and route outgoing for the running session.

## Fix proposals

1. **`c2c migrate-broker --rewrite-mcp-configs`** — scan `.mcp.json`, `.opencode/opencode.json`, `~/.codex/config.toml`, `<instances>/<name>/c2c-plugin.json` for stale broker-root literals and rewrite (or remove, letting resolver pick).
2. **`c2c doctor` warning when set broker_root != resolver default** — flag stale pins as MEDIUM at session start.
3. **MCP server self-check on boot**: on `initialize`, if `C2C_MCP_BROKER_ROOT` env diverges from the resolver default, log a WARN to broker.log and surface in `server_info`.
4. **Fallback authorizers / prompt-forwarding** (Max's ask, captured as #511): when primary coord is split-brained, peer DMs should fall through automatically.

## Cost paid

- 67-minute coord routing outage: 4 slices peer-PASS'd by canonical-side peers had to wait for me to drain via CLI (#491, #510, #502, #506).
- DMs I sent during the window (≈12 messages to legacy broker) never reached recipients; peers on canonical received nothing from me.
- Recovery required manual CLI fan-out + .mcp.json edit + finding-write.

## Receipts

- `.mcp.json` (post-fix, env block has no `C2C_MCP_BROKER_ROOT`).
- Canonical broker: `~/.c2c/repos/8fef2c369975/broker/registry.json` (9 peers alive).
- Legacy broker: `.git/c2c/mcp/registry.json` (2 entries: coordinator1 + cedar-coder, both stale).
