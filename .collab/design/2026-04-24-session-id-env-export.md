# Session ID env var export for managed sessions

**Author**: galaxy-coder
**Date**: 2026-04-24
**Status**: Designed, implementation blocked on Max's concurrent pmodel work in c2c_start.ml

## Problem

Child shells/CLIs spawned from a `c2c start` managed session cannot self-identify back to the parent session without walking `/proc`. This is the root cause of session-hijack footguns when launching child agents (e.g., `kimi -p`, `codex`) from within a Claude Code session.

Claude Code does NOT export `CLAUDE_CODE_SESSION_ID` to the Bash tool environment — only `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, etc. This is confirmed by Max: `env | grep CLAUDE` inside a Claude Code Bash tool returns no session ID.

## Design

### Env vars to export

| Client | Env var | Value | Notes |
|--------|---------|-------|-------|
| claude | `CLAUDE_CODE_PARENT_SESSION_ID` | `name` | CC generates its own session ID internally; we export PARENT hint |
| codex | `CODEX_THREAD_ID` | `name` | Codex accepts session IDs directly |
| opencode | `OPENCODE_SESSION_ID` | `name` | OpenCode accepts session IDs directly |
| kimi | `KIMI_SESSION_ID` | `name` | Kimi accepts session IDs directly |
| crush | `CRUSH_SESSION_ID` | `name` | Crush accepts session IDs directly |

Note: `name` is the instance name (e.g., "galaxy-coder"), not a UUID. For clients that generate their own session IDs (Claude Code), we can't match their internal ID — `CLAUDE_CODE_PARENT_SESSION_ID` signals "this is the session that launched this process, but it's not guaranteed to match CC's internal ID."

### Implementation location

`ocaml/c2c_start.ml`, `run_outer_loop` function, after `build_env` returns.

The `build_env` function doesn't take a `client` parameter, so add client-specific env vars after the `build_env` call, following the existing pattern:

```ocaml
let client_session_env =
  match client with
  | "claude"   -> [| "CLAUDE_CODE_PARENT_SESSION_ID=" ^ name |]
  | "codex"    -> [| "CODEX_THREAD_ID=" ^ name |]
  | "opencode" -> [| "OPENCODE_SESSION_ID=" ^ name |]
  | "kimi"     -> [| "KIMI_SESSION_ID=" ^ name |]
  | "crush"    -> [| "CRUSH_SESSION_ID=" ^ name |]
  | _ -> [||]
in
let env = Array.append env client_session_env in
```

### Also: Remove --channels server:c2c from Claude launch args

Per Max's explicit call (coordinator1 relayed 2026-04-24): remove `--channels server:c2c` from `dev_channel_args` in `prepare_launch_args` (lines 1019-1025) but keep `--dangerously-load-development-channels server:c2c`. Reason: prevents parser confusion in cc-* wrapper scripts.

Update the cc-wrapper comment (lines ~1696-1700) to remove the `--channels` reference.

### Blocking issue

Max is actively working on `model_override` / pmodel support in `c2c_start.ml`. Build fails with his uncommitted changes if we touch the file. Wait for his pmodel work to land or merge before implementing session ID env vars.

## Test plan

1. Start a managed Claude session: `c2c start claude -n test-session`
2. Inside a Bash tool, run: `env | grep -E "(CLAUDE_CODE|CODEX|OPENCODE|KIMI|CRUSH)_SESSION"`
3. Verify `CLAUDE_CODE_PARENT_SESSION_ID=test-session` is set
4. Repeat for other client types
5. Verify child CLIs (e.g., `kimi -p`) can read the env var and use it for self-identification
