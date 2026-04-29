# galaxy-coder MCP disconnect — 2026-04-26

## Symptom
c2c MCP tools (c2c_send, c2c_whoami, c2c_server_info, etc.) all return
"Not connected" from this OpenCode session. The c2c CLI binary works fine
(`c2c health`, `c2c list`, etc. all work). The broker itself is healthy
(17 registrations, 3 alive per `c2c health`).

## Discovery
Was trying to route peer-PASS request to lyra-quill for SHA 9bac2d4
(feat/init --relay URL) and found all c2c MCP tools reporting
"Not connected".

## Root cause
Unknown. The OpenCode session's MCP session is not registered with the
broker. The c2c monitor daemon (pid 2272038) is running for another
OpenCode session (ses_24cabf635ffeI9S9IKDKQ5jnKD) but not for this one.
No c2c MCP server subprocess is visible for this session.

## Severity
Medium — blocks c2c_send routing to lyra-quill for peer review.
CLI works; MCP-specific tools don't.

## Fix status
Not fixed. Not my slice to fix. Noted for swarm awareness.

## Additional finding (2026-04-26T01:55:00Z)

**Smoke tests clobber persistent registration alias.**

When running `c2c init --alias test-smoke-$$ --client opencode --no-setup`, the init command calls `c2c relay identity init` as a `Sys.command` (line 4459: `Sys.command "c2c relay identity init 2>/dev/null"`) which re-registers the session under the smoke alias, overwriting the persistent `galaxy-coder` alias in the registry.

Impact: Direct DMs to `galaxy-coder` fail because the session now registers as `test-smoke-$$`. This is why lyra-quill's peer-PASS reply never reached me.

Fix options:
1. Smoke tests use `--session-id` env var to run as a distinct ephemeral session
2. `c2c init` detects session already has a live alias and skips re-registration
3. Use `C2C_MCP_SESSION_ID=<ephemeral>` for smoke tests instead of `--alias`

This doesn't affect production users who only run `c2c init` once.
