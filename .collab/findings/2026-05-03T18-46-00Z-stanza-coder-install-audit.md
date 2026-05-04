# c2c install self-configuration audit

**Found by:** stanza-coder  
**Date:** 2026-05-03  
**Severity:** Medium (config drift across clients)  
**Status:** Findings 1–3 CLOSED (code fix 7198adea); Finding 6 CLOSED (code fix d6b99be0 — `mkdir_p` used instead of `mkdir_or_dryrun`); Findings 4–5 open (nice-to-have)

## Methodology

Ran `c2c install all --dry-run` and manually inspected installed configs
for claude, opencode, kimi, and codex. Compared env vars, broker root
paths, and session handling across all four.

## Finding 1: Kimi uses legacy broker root path

**Severity: High — messages may route to wrong broker**

Kimi's `~/.kimi/mcp.json` has:
```json
"C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c/.git/c2c/mcp"
```

This is the **legacy** path. The canonical broker root is:
```
/home/xertrov/.c2c/repos/8fef2c369975/broker
```

OpenCode's config correctly uses the new path. Claude's `.mcp.json`
doesn't set it at all (auto-detected, which resolves correctly).

**Impact:** If the legacy path has stale data or doesn't exist, kimi
would fail to find the broker or talk to a ghost broker.

**Fix:** Re-run `c2c install kimi --force` or manually update
`~/.kimi/mcp.json` to use the canonical broker root.

**Resolution (2026-05-03):** Code fix landed at 7198adea (removed SESSION_ID,
added AUTO_DRAIN_CHANNEL=0). `c2c install kimi --force` verified — config now
has canonical broker root. Note: first run hit `Sys_error` for missing
`~/.c2c/clients/kimi/` dir (see Finding 6 below); `mkdir -p` + re-run succeeded.

## Finding 2: Kimi has hardcoded session_id and alias

Kimi's `~/.kimi/mcp.json` has:
```json
"C2C_MCP_SESSION_ID": "kuura-viima",
"C2C_MCP_AUTO_REGISTER_ALIAS": "kuura-viima"
```

Other clients (claude, opencode) do NOT hardcode these — `c2c start`
manages session_id and alias dynamically. The hardcoded values mean:

1. All kimi instances share the same session_id (collision risk)
2. Alias is locked to "kuura-viima" regardless of role assignment
3. If kimi is launched via `c2c start kimi`, the managed session's
   env vars override these, but a standalone `kimi` launch would
   use the stale config

**Fix:** Re-run `c2c install kimi --force` to get a config without
hardcoded session/alias (managed sessions inject these at launch).

**Resolution (2026-05-03):** Code fix at 7198adea removed SESSION_ID from
kimi/gemini/crush static configs. Verified via `c2c install kimi --force` —
new config has only AUTO_REGISTER_ALIAS (no SESSION_ID).

## Finding 3: Env var inconsistency across clients

| Env var | Claude | OpenCode | Kimi |
|---------|--------|----------|------|
| `C2C_MCP_BROKER_ROOT` | (auto) | ✓ new path | ✗ legacy |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | (not set) | `0` | (not set) |
| `C2C_MCP_CHANNEL_DELIVERY` | `1` | (not set) | (not set) |
| `C2C_MCP_DEBUG` | `1` | (not set) | (not set) |
| `C2C_CLI_COMMAND` | (not set) | ✓ | (not set) |
| `C2C_AUTO_JOIN_ROLE_ROOM` | (not set) | `1` | `1` |
| `C2C_MCP_AUTO_JOIN_ROOMS` | `swarm-lounge` | `swarm-lounge` | `swarm-lounge` |
| `C2C_MCP_SESSION_ID` | (not set) | (not set) | hardcoded |

Notable gaps:
- Claude has `C2C_MCP_CHANNEL_DELIVERY=1` but opencode/kimi don't
- OpenCode has `C2C_AUTO_DRAIN_CHANNEL=0` but claude/kimi don't set it
- `C2C_CLI_COMMAND` only in opencode — should probably be in all
- `C2C_AUTO_JOIN_ROLE_ROOM` missing from claude config

These may be intentional per-client differences, but the inconsistency
suggests the install code paths diverged over time.

## Finding 4: `c2c install all --dry-run` only shows unconfigured clients

Running `c2c install all --dry-run` only showed gemini (unconfigured).
It skipped claude, opencode, codex, kimi because they're already
configured. This means the dry-run can't be used to audit what the
installer *would* write for already-configured clients.

**Suggestion:** Add a `--force --dry-run` mode that shows what would
be written even for already-configured clients — useful for auditing
config drift.

## Finding 5: No `~/.c2c/clients/` directory

The `~/.c2c/` directory has no `clients/` subdirectory. The dry-run
for gemini showed `[DRY-RUN] would create directory ~/.c2c/clients/gemini`,
suggesting this is a per-install artifact. Not a bug — just noting
that currently-installed clients were set up before this directory
structure existed.

## Finding 6: `c2c install kimi --force` crashes if `~/.c2c/clients/kimi/` doesn't exist

**Severity: Low — installer should mkdir -p before writing**

Running `c2c install kimi --force` when `~/.c2c/clients/kimi/` doesn't exist
produces:
```
Sys_error("/home/xertrov/.c2c/clients/kimi/deliver-watch.sh: No such file or directory")
```

The config at `~/.kimi/mcp.json` is still written correctly (the crash happens
after config write), but the exit code is 125 and the `deliver-watch.sh` is
not created.

**Fix:** Add `mkdir_p` call before writing to `~/.c2c/clients/<client>/` in the
installer. Probably a one-liner in `c2c_setup.ml`.

**Resolution (2026-05-03):** willow-coder fixed in d6b99be0 (`fix(install): mkdir_p for client dirs`).
Both `~/.kimi/` and `~/.c2c/clients/kimi/` now use `mkdir_p` instead of `mkdir_or_dryrun`,
so intermediate directories are created automatically on fresh hosts.

## Cross-references

- Broker root migration: `c2c migrate-broker`
- CLAUDE.md § Broker root resolution order
- Kimi delivery: `.collab/runbooks/kimi-notification-store-delivery.md`
