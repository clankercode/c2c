# deferrable=true flag is not honored on push delivery path

**Discovered:** 2026-04-25 17:01 UTC+10
**Reporter:** coordinator1 (Cairn-Vigil), test ran by dogfood-hunter
**Severity:** medium — semantic-correctness bug, not a delivery failure

## Symptom

dogfood-hunter sent two test messages:
1. T5: `c2c send coordinator1 "[T5-deferred] ..."` (no flag — control)
2. T5-retry: `c2c send coordinator1 "[T5-retry deferrable=true] ..."` with explicit `deferrable=true`

Both arrived via channel-notification push (visible in coordinator1's transcript as `<channel source="c2c">` system-reminder injections), within seconds of send.

Per CLAUDE.md and the `mcp__c2c__send` tool documentation:

> Optional `deferrable:true` marks the message as low-priority: push paths (channel notification, PostToolUse hook) skip it — recipient reads it on next explicit poll_inbox or idle flush.

So T5-retry should have been silent on the push path. It was not.

## Hypothesis

Either (a) the `deferrable` flag is not being persisted to the inbox envelope, (b) the channel notification emitter is ignoring the flag, or (c) the dogfood-hunter CLI/MCP call did not actually pass the flag despite the body claim. (c) is plausible since the prior test showed literal `$(date +%s.%N)` in the body, suggesting CLI quoting issues.

## Suggested investigation

1. Confirm the actual MCP/CLI call dogfood-hunter ran (capture the wire-level JSON for the `mcp__c2c__send` invocation, or the `c2c send` argv).
2. Inspect the inbox envelope for the message — is the `deferrable` field set?
3. Check `c2c_mcp.ml` channel-notification emitter for `deferrable` handling.
4. Check the CLI `c2c send` to confirm it accepts and forwards a `--deferrable` flag (it may not — see CLAUDE.md `c2c_send.py` signature, which lists `--dry-run --json` but not `--deferrable`).

## Suggested fix scope

If CLI doesn't expose `--deferrable`: add it. If the MCP path doesn't honor it: fix the notification suppression. Either way, write an integration test that verifies a deferrable=true message lands in inbox via poll_inbox but does NOT trigger the push notification.

## Cross-refs

- CLAUDE.md `mcp__c2c__send` doc
- `.c2c/worktrees/stanza-coder/c2c_send.py` (Python shim)
- `ocaml/c2c_mcp.ml` (channel_notification emitter)
