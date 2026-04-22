# A9: `c2c commands` shows Tier 3 commands that are unavailable in agent sessions

**Date:** 2026-04-23
**Author:** CEO
**Status:** FIXED `1fe8a2a`

## Bug Description

`c2c commands` lists Tier 3 commands (relay serve, relay gc, relay setup, relay connect, relay register) but when running inside an agent session (C2C_MCP_SESSION_ID is set), these commands are not actually reachable via the dispatcher.

**Repro:**
```bash
# In agent session:
c2c commands | grep relay   # shows relay serve, relay gc, etc.
c2c relay --help           # "unknown command relay"
```

**Root Cause:** `commands_by_safety_cmd` in `c2c.ml` always prints Tier 3 regardless of `is_agent_session()`, but the CLI dispatcher (`filter_commands` + `visible_cmds`) filters out Tier 3 commands when `C2C_MCP_SESSION_ID` is set.

The `c2c commands` output is therefore misleading — it shows commands you cannot actually run.

## Fix

In `commands_by_safety_cmd`, skip printing Tier 3 when `is_agent_session ()` returns true, matching the dispatcher's behavior:

```ocaml
if not (is_agent_session ()) then print_section (safety_to_label Tier3) tier3;
```

## Verification

```bash
# Outside agent: Tier 3 visible
env -u C2C_MCP_SESSION_ID c2c commands | grep "TIER 3"
# == TIER 3 — UNSAFE FOR AGENTS (systemic, requires operator) ==

# Inside agent: Tier 3 hidden
C2C_MCP_SESSION_ID=test c2c commands | grep "TIER 3"
# (no output)
```

(End of file)