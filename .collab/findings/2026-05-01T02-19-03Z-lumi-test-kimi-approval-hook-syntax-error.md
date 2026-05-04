# Kimi Approval Hook Bash Syntax Error — `stash list` Unquoted in `case` Pattern

**Severity:** HIGH (blocks all Shell tool execution for kimi agents on affected host)  
**File:** `/home/xertrov/.local/bin/c2c-kimi-approval-hook.sh`  
**Line:** 80  
**Discovered by:** lumi-test during #593 peer review  
**Fix status:** Fixed in place by lumi-test

## Symptom

Every `Shell` tool invocation failed immediately with:

```
ERROR: /home/xertrov/.local/bin/c2c-kimi-approval-hook.sh: line 80: syntax error near unexpected token `list'
```

This rendered the agent unable to run builds, tests, or any shell commands.

## Root Cause

In the `is_safe_command()` function, the `git` subcommand allowlist uses a bash `case` statement with unquoted multi-word patterns:

```bash
      case "$sub" in
        status|log|diff|show|branch|tag|remote|config|rev-parse|\
        rev-list|describe|blame|reflog|ls-files|ls-tree|stash list|fetch|\
        shortlog|count|status|-h|--help)
```

The pattern `stash list` contains a space. In bash `case` syntax, unquoted spaces separate patterns, so `list` is parsed as a standalone token outside the `case ... in` construct, causing a syntax error at script parse time — the entire script fails before it can process any command.

## Fix

Quoted the multi-word pattern:

```bash
        rev-list|describe|blame|reflog|ls-files|ls-tree|"stash list"|fetch|\
```

Shell execution restored immediately.

## Follow-up

The embedded copy in `ocaml/cli/c2c_kimi_hook.ml` (the actual deployed version per file header) should be checked for the same bug. **Update:** stanza-coder audited `c2c_kimi_hook.ml:143` and confirmed it contains only bare `stash` (no space), so the embedded source is NOT vulnerable. The `(deleted)` binary on-disk mismatch for running notifiers is a separate operational issue (findings doc 2026-05-01T03-30-00Z).
