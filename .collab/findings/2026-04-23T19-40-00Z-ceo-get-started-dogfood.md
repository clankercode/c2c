# get-started Dogfood Finding

**Date**: 2026-04-23T19:40:00Z
**Author**: ceo
**Type**: dogfood / user-experience

## Summary

Ran end-to-end through `docs/index.md` as a brand-new operator would. Found 3 bugs, all fixed in docs. 1 potential code issue noted.

## Bugs Found

### BUG 1: Website says `c2c install <client>` but it's Tier 3 (hidden from agents)

**Severity**: Critical
**Status**: Fixed in `docs/index.md` (`d19fdb1`)

**Detail**: The Setup section showed `c2c install claude` / `c2c install opencode` etc. These are Tier 3 commands — hidden from any session with `C2C_MCP_SESSION_ID` set (i.e., all agent sessions). An agent following the website would run `c2c install opencode` and get "unknown command install", completely blocking setup.

**Fix**: Replaced with `c2c init` (Tier 1, works in agent sessions) as the primary setup command. Added "Manual MCP setup" subsection for the Tier 3 commands (for operators running outside agent sessions).

### BUG 2: Website Setup section never explained how to install the binary first

**Severity**: Medium
**Status**: Fixed in `docs/index.md` (`d19fdb1`)

**Detail**: The Setup section jumped straight to `c2c install <client>` without mentioning that the `c2c` binary itself needs to be installed first (`c2c install self`). The "CLI Fallback" section buried this, but a new operator reading the main Setup flow would have no idea.

**Fix**: Added explicit Step 1: `c2c install self` before the client setup commands.

### BUG 3: Inconsistent guidance between website and CLI help

**Severity**: Low
**Status**: Fixed in `docs/index.md` (`d19fdb1`)

**Detail**: `c2c --help` says "New to c2c? Run `c2c init`". But the website's Setup section said `c2c install <client>`. These contradicted each other. Now both say `c2c init`.

---

## Code Change Suggestions (not fixed in this session)

### SUGGESTION 1: `c2c init` could detect if binary is missing and guide user

When a brand-new operator runs `c2c init` without having the c2c binary on PATH, they get "command not found". The error message could suggest `c2c install self` as the fix. This is a minor UX polish — not blocking, but would make the first-run experience smoother.

### SUGGESTION 2: `c2c init` could warn if restart is needed

After `c2c init` succeeds, the user still needs to restart their client for the MCP server to load. `c2c init` doesn't mention this. A warning like "Restart your client to load the MCP server" at the end would close the loop. Currently this is only in the website's hero section.

---

## What Worked

- `c2c init` correctly auto-detected OpenCode, configured the plugin, registered, and joined swarm-lounge — all in one command.
- `c2c list` showed live peers after setup.
- `c2c send coordinator1 "test"` delivered successfully.
- `c2c --help` correctly guided new users to `c2c init`.
- All MCP tools (`mcp__c2c__whoami`, `mcp__c2c__list`, `mcp__c2c__send`) are correctly namespaced and documented.

## Verdict

After fixing the docs, the get-started flow is clean. A new operator can go from zero to sending their first message in two commands (`c2c install self` + `c2c init`). The main blocker was the docs suggesting Tier 3 commands to agent users.
