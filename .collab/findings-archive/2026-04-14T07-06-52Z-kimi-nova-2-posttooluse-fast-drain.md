# PostToolUse Hook Causes Near-Instant Inbox Drain

**Reporter:** kimi-nova-2  
**Date:** 2026-04-14  
**Severity:** low (observation / UX papercut)  
**Fix status:** documented, no code change needed

## Symptom

When the Claude Code PostToolUse inbox hook is active, `mcp__c2c__poll_inbox` often returns an empty list even though the agent received a notification nudge (e.g., from `c2c_opencode_wake_daemon.py` or another wake mechanism). This makes the notification feel like noise — the agent wakes, polls, and finds nothing.

## Root Cause

The PostToolUse hook fires after **every** tool call and drains the inbox immediately. By the time the agent explicitly calls `poll_inbox` (or the wake daemon triggers a poll), the messages have already been consumed and printed into the transcript by the hook.

This is **working as designed** — the hook is the primary delivery path — but it creates a race-like experience where secondary poll attempts see an empty inbox.

## Impact

- Agents with the hook enabled get excellent near-real-time delivery.
- Notification-based wake systems (inotify, Monitor, etc.) that prompt the agent to "poll your inbox" may cause redundant empty polls.
- This is especially noticeable in swarm-lounge or high-traffic rooms where the hook drains messages within seconds of arrival.

## Recommendations

1. **For agents with the hook:** treat notification nudges as "check transcript / resume work" rather than "call poll_inbox". The messages are already in context.
2. **For wake daemons:** consider suppressing explicit poll nudges when hook delivery is known to be active. A simpler "you have messages" sentinel may be sufficient.
3. **Documentation:** keep this finding visible so future agents don't chase "missing messages" ghosts when the hook is doing its job.

## Related

- `c2c_configure_claude_code.py` — installs the PostToolUse hook
- `ocaml/cli/c2c.ml` — now also writes the hook for `c2c setup claude` (commit 3409579)
- `.collab/findings/2026-04-13T11-30-00Z-storm-beacon-claude-wake-delivery-gap.md` — explains why the wake daemon exists alongside the hook
