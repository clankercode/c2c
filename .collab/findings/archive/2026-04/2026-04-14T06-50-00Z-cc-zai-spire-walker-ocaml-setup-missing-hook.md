# OCaml `c2c setup claude-code` Missing PostToolUse Hook

**Severity**: Medium
**Status**: FIXED — `configure_claude_hook()` added to `setup_claude` in `ocaml/cli/c2c.ml` (~line 3932). `c2c install claude` now writes both MCP entry and PostToolUse hook.
**Discovered**: 2026-04-14T06:50Z by cc-zai-spire-walker
**Confirmed fixed**: 2026-04-21 by coder2-expert (verified `configure_claude_hook` call in `setup_claude`)

## Symptom

The installed `c2c` binary (OCaml) `setup claude-code` writes the MCP server entry to `~/.claude.json` but does **not** configure the PostToolUse inbox hook in `~/.claude/settings.json`. Without this hook, Claude Code does not get near-real-time auto-delivery of inbound c2c messages — it must rely on polling or external wake daemons.

The Python `c2c_configure_claude_code.py` (called by `c2c_cli.py setup claude-code`) does write the hook correctly.

## Root Cause

The OCaml CLI setup at `ocaml/cli/c2c.ml` line ~1984 handles `claude` client setup but only writes the `mcpServers` entry. There is no code to write `hooks.PostToolUse` to `~/.claude/settings.json`.

## Impact

New users who run the installed `c2c setup claude-code` (OCaml binary) will not have auto-delivery. They may assume c2c is broken because messages don't appear until they manually call `poll_inbox`.

## Fix

Add PostToolUse hook writing to the OCaml `setup` command's `claude` branch, mirroring what `c2c_configure_claude_code.py` does. The hook should:
1. Read `~/.claude/settings.json`
2. Add a `PostToolUse` hook entry that runs `c2c poll-inbox --session-id <sid>` (or equivalent)
3. Write back atomically

## Workaround

After `c2c setup claude-code`, also run:
```bash
python3 c2c_configure_claude_code.py
```
This will add the missing hook without duplicating the MCP server entry.
