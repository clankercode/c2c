---
title: ECHILD hook errors regressed — two divergent writers re-broke the fix
date: 2026-04-20T12:57:10Z
author: coder2-expert
severity: medium — noisy transcript + intermittent user-visible errors; hooks still ran
---

# Symptom

Max (m@xk.io) reported via coordinator1 that Claude Code hook errors
returned on his live session:

```
UserPromptSubmit hook error — Failed with non-blocking status code:
  Error occurred while executing hook command: ECHILD: unknown error, waitpid
PostToolUse:ToolSearch hook error — Failed with non-blocking status code:
  Error occurred while executing hook command: ECHILD: unknown error, waitpid
```

Timing was intermittent — one round hit both, another round only fired
UserPromptSubmit. Both are the classic Node.js/libuv fast-exit race
already documented in
`2026-04-19T09-08-00Z-opus-host-posttooluse-hook-echild-race.md`.

# Root causes (two distinct regressions)

## 1. `setup_claude` writes an exec-style hook, overwriting the canonical fix

`ocaml/cli/c2c.ml` contains two hook-script writers:

- `claude_hook_script` / `configure_claude_hook` (~line 2523) — the
  canonical post-fix body: plain `c2c hook; exit 0`, no `exec`.
- `setup_claude` (~line 2673-2691) — hardcoded a *separate* inline
  body that still ended with `exec timeout 5 c2c hook`. Every
  `c2c install claude` run silently clobbered the canonical fix in
  `~/.claude/hooks/c2c-inbox-check.sh`.

This is exactly the failure mode the prior finding warned about:
bash execs into c2c mid-flight, Claude Code's libuv waitpid()
bookkeeping gets confused, and ECHILD surfaces on non-MCP tool
calls whenever the inbox had content.

## 2. idle-info plugin: marketplaces/ patched, cache/ unpatched

Prior fix for `UserPromptSubmit`/`Stop`/`PreCompact` ECHILD wrapped
each node invocation with a 50ms sleep floor. The patch was applied
to:

- `~/.claude/plugins/marketplaces/idle-info/hooks/hooks.json` ✅

But Claude Code loads from:

- `~/.claude/plugins/cache/idle-info/idle-timing/0.3.0/hooks/hooks.json` ❌

The cache file still contained the original unpatched commands, so
the sleep never actually fired and `UserPromptSubmit` kept racing.
Easy to miss — timestamps confirmed marketplaces was newer, cache
was the old install.

# Fix applied in this session

1. **Patched `~/.claude/hooks/c2c-inbox-check.sh` directly** with the
   canonical body so Max's live session gets immediate relief (no
   restart needed — the hook is re-read each invocation).

2. **Edited `ocaml/cli/c2c.ml`** to have `setup_claude` use the
   canonical `claude_hook_script` instead of its own inline string:
   ```
   let hook_content = claude_hook_script in
   ```
   Rebuilt with `dune build -j1`, installed via
   `install -m 0755 ... ~/.local/bin/c2c.new && mv -f`
   (direct `cp` failed with "Text file busy" because the current
   session's MCP server was running the old binary).

3. **Patched the cache idle-info hooks.json** with the 50ms-sleep
   wrapper pattern matching the marketplaces copy.

4. **Verified** by rerunning `c2c install claude --force` and
   inspecting the re-written hook file — it now contains the
   canonical no-exec body.

# Follow-ups / open questions

- The cache patch is still fragile: any plugin update from the
  marketplace will re-sync the cache and blow the fix away. We
  should either:
  - Upstream the sleep-wrapper to the idle-info plugin's
    repository (`clankercode/claude-inject-idle-time`), or
  - Wrap the whole thing in a post-install step c2c applies on
    plugin sync, or
  - Ship our own small wrapper script rather than depending on
    a third-party plugin.
- The `install` command still prints "(hook was already registered
  — no changes made)" even when it rewrites the script body. That
  message is misleading — it refers only to the settings.json hook
  registration, not the script contents. Consider tightening.
- Worth adding a test that asserts the written hook script does
  NOT contain the literal string `exec `, so we catch any future
  regression automatically.

# Related

- Prior finding: `2026-04-19T09-08-00Z-opus-host-posttooluse-hook-echild-race.md`
- Claude Code version: 2.1.114.
- Node.js / libuv waitpid race: https://github.com/nodejs/node/issues/37037
