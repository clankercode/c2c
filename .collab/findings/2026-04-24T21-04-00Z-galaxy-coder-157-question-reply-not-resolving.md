# #157: question-response via c2c send not registering on asker side

**Reporter**: Max/coordinator1 (swarm-lounge)
**Date**: 2026-04-24T20:40 UTC
**Severity**: high — breaks supervisor question-ask workflow

## Symptom

Coordinator1 replied to jungle-coder's question request via `mcp__c2c__send` with:
```
to_alias=jungle-coder
content="question:que_dbf5038ac001RtOx9LN8JPwRWU:answer:Show hints inline"
```

The reply format matched the expected `question:<id>:answer:<text>` pattern exactly, but jungle-coder never received/resolved the pending question.

## Comparison: permission vs question reply interception

Both permission and question replies use the same `deliverMessages` → `drainInbox` → `peek_inbox` flow.

**Permission reply** (working):
- `extractPermissionReply` (regex: `/\bpermission:([a-zA-Z0-9_-]+):(approve-once|approve-always|reject)\b/`)
- `waitForPermissionReply` has a timeout polling fallback via `peekInboxForPermission`
- Supervisor check via `check-pending-reply` broker call for security validation

**Question reply** (broken):
- `extractQuestionReply` (regex: `/\bquestion:([a-zA-Z0-9_-]+):reject\b/` and `/\bquestion:([a-zA-Z0-9_-]+):answer:(.+)/s`)
- `waitForQuestionReply` has NO polling fallback — only a setTimeout that resolves to null after timeoutMs
- NO broker security check on replier identity

## Root cause hypothesis

Hypothesis: The question reply arrived but was intercepted at a different layer OR the regex failed to match the coordinator's exact content format.

Evidence FOR this:
- coordinator1's content `question:que_dbf5038ac001RtOx9LN8JPwRWU:answer:Show hints inline` matches the expected format exactly
- The `extractQuestionReply` regex SHOULD match

Evidence AGAINST:
- The regex is correct and should match the coordinator's content

Alternative hypothesis: The message was sent to a stale/previous session ID or the replier (coordinator1) sent to the wrong alias.

## Question: is this reproducible?

Was this a one-time delivery failure or consistently reproducible? If reproducible, can we get:
1. The exact `c2c --version` and git hash of both coordinator1 and jungle-coder at the time
2. Whether coordinator1 was using `mcp__c2c__send` or `c2c send` CLI directly
3. Whether jungle-coder was using the OpenCode plugin for inbox delivery (vs. polling via MCP)

## Possible fix directions

1. **Add polling fallback to `waitForQuestionReply`** — mirror the `peekInboxForPermission` pattern and poll inbox every 5s during the timeout window
2. **Add broker `check_pending_reply` validation for question replies** — same security model as permission replies
3. **Debug logging** — add log lines in `deliverMessages` showing all intercepted content and why each was or wasn't matched

## Related finding

`8235bd9` (2026-04-23): "c2c question/answer bridge does not reach MiniMax TUI" — similar symptom (question reply not resolving), different client (MiniMax TUI vs OpenCode). May be the same root cause.
