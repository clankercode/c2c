# #338 (#334b): Shared-repo `.mcp.json` shape + coordinated swarm migration

**Author:** coordinator1 (Cairn-Vigil)
**Date:** 2026-04-28T05:46:00Z
**Status:** design proposal
**Issue:** #338, follow-up to #334

## 1. Problem

After #334, `c2c install claude` defaults to writing a project-level
`.mcp.json` at the repo root. The current shape inlines per-agent
identifiers into the committed file:

```json
{
  "mcpServers": {
    "c2c": {
      "command": "c2c-mcp-server",
      "env": {
        "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c/.git/c2c/mcp",
        "C2C_MCP_AUTO_REGISTER_ALIAS": "alice",
        "C2C_MCP_SESSION_ID": "...",
        "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge"
      }
    }
  }
}
```

Two leaks make this hostile to a shared repo:

1. **Identity leak** — `C2C_MCP_AUTO_REGISTER_ALIAS=alice` committed
   means bob's clone auto-registers as alice on first MCP boot. This
   silently hijacks routing the moment bob's session starts.
2. **Filesystem leak** — `C2C_MCP_BROKER_ROOT` pins an absolute host
   path (`/home/xertrov/...`). Any other host either fails outright
   or, worse, writes broker state to a path that doesn't match the
   client's expectations.

Single-developer use is fine; any repo with two or more agents is
broken on clone.

## 2. Constraints

- **Shared-safe** — committing `.mcp.json` to `origin/master` must
  not encode any agent's identity, session, or absolute filesystem
  path.
- **Idempotent install** — `c2c install <client>` must be safe to
  re-run; it should add the agent's local identity to a gitignored
  sidecar without rewriting the committed file.
- **Migration-friendly** — the running swarm already has populated
  `.mcp.json` files in active worktrees. The transition must not
  break peers who are currently delivering messages.

## 3. Proposed shape

Split into two layers:

### 3a. `.mcp.json` (committed, shared)

Server invocation only. No per-agent env. Broker root resolved by
the server's existing fallback chain (`$XDG_STATE_HOME/c2c/repos/<fp>/broker`
→ `$HOME/.c2c/repos/<fp>/broker`), which is already host-portable
post coord1's 2026-04-26 change.

```json
{
  "mcpServers": {
    "c2c": {
      "type": "stdio",
      "command": "c2c-mcp-server",
      "args": [],
      "env": {
        "C2C_MCP_CHANNEL_DELIVERY": "1"
      }
    }
  }
}
```

Only env vars that are **identical for every agent in the swarm**
belong here. `C2C_MCP_CHANNEL_DELIVERY` qualifies; `AUTO_REGISTER_ALIAS`
and `BROKER_ROOT` do not.

### 3b. Per-agent local override (gitignored)

Two surfaces, in priority order:

1. **`.mcp.local.json`** at repo root — Claude Code already merges
   this on top of `.mcp.json` (deep-merged env). Add to `.gitignore`.
   Written by `c2c install <client> --shared`. Contains:
   ```json
   {
     "mcpServers": {
       "c2c": {
         "env": {
           "C2C_MCP_AUTO_REGISTER_ALIAS": "alice",
           "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge"
         }
       }
     }
   }
   ```
2. **Process env** — `c2c start <client>` already exports
   `C2C_MCP_SESSION_ID` and friends into the child's environment.
   This is the right home for ephemeral per-launch values
   (`SESSION_ID`) that should not survive a session.

The c2c MCP server reads env on startup as today; no server change
needed. The override layering is a Claude Code feature we lean on
rather than re-implementing.

## 4. Migration plan

The swarm has live agents with populated `.mcp.json` files. Cannot
flip a default and break delivery mid-flight.

**Phase 1 — opt-in flag (this slice).**
- Add `c2c install <client> --shared`. Behaviour:
  - Writes the alias-less `.mcp.json` shape above.
  - Writes/updates `.mcp.local.json` with the agent's identity.
  - Adds `.mcp.local.json` to `.gitignore` if missing.
- Default (no `--shared`) is unchanged: today's per-agent shape.
- Document in `docs/install.md` and the install-claude runbook.

**Phase 2 — announce + migrate.**
- DM swarm in `swarm-lounge` with one-line migration:
  `c2c install claude --shared` re-runs install in shared mode.
- Coordinator1 tracks per-agent migration state (similar to the
  signing rollout). Each agent restarts its session after migrating;
  on restart the new `.mcp.local.json` takes effect.
- During Phase 2 both shapes coexist; agents that haven't migrated
  keep working off the old per-agent committed shape, since their
  worktree's `.mcp.json` is still keyed to them.

**Phase 3 — flip default.**
- Once every active alias confirms PASS on a smoke send under the
  new shape, flip `--shared` to be the default and add
  `--legacy-per-agent` for the rare single-developer case.
- Ship a `c2c doctor mcp-shape` check that flags committed
  `.mcp.json` files containing per-agent env vars, so future drift
  is visible.

## 5. Open questions

- **`C2C_MCP_AUTO_JOIN_ROOMS` — shared or per-agent?** `swarm-lounge`
  is universal, so it could live in committed `.mcp.json`. But a
  role-specific room (e.g. coordinator-only) belongs in the local
  override. Proposal: committed shape carries the universal default
  (`swarm-lounge`); per-agent override appends to it. Need to
  confirm Claude Code's env merge semantics — string-replace, not
  list-append, so concatenation has to happen at the local-override
  authoring step.
- **`.mcp.local.json` precedence across clients.** Codex, OpenCode,
  Crush, Kimi all have different config surfaces. Phase 1 ships
  Claude-only; per-client local-override paths for the other four
  need their own slice (likely #338b).
- **Bootstrapping a fresh clone.** A user running `git clone` then
  `claude` with no `c2c install` gets the committed `.mcp.json`
  with no alias. Should the broker auto-prompt? Auto-pick a fresh
  alias from the pool? Today the broker handles unregistered
  sessions gracefully — confirm this still holds when there's no
  `AUTO_REGISTER_ALIAS` at all.
- **Existing `.mcp.json` in the c2c repo itself.** This very file
  still has `coordinator1`-flavoured env (well, `xertrov`'s
  worktree path). Treat the c2c repo as the first migration target
  in Phase 2.
