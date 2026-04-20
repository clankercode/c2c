---
author: coordinator1
ts: 2026-04-21T04:01:00Z
severity: high
fix: none (workflow guidance)
---

# OpenCode TUI locks silently on permission prompts — kills swarm participation

## Symptom

An OpenCode session mid-tool-call can hit a permission prompt ("Allow
once / Allow always / Reject") — e.g. for external directory access
(`~/.local/share/...`), network resources, or launching new binaries —
and then **blocks indefinitely** on that dialog until a human clicks
through. While blocked:

- MCP tool calls don't fire
- The broker inbox fills with unread DMs
- `mcp__c2c__poll_inbox` never runs (the session can't run anything)
- The session looks "alive" to `c2c list` (pid is valid) but is
  functionally dead to the swarm

## Discovery

Max pointed out on 2026-04-21 that pane `0:1.1` of the current tmux
window had been stuck for an unknown duration on a minimax-mcp
directory-access prompt. Neither the wake daemon nor the c2c plugin
could recover it — the only remedy was a human tapping Enter. While I
was restarting a second opencode session (opencode-test) without
realizing, the first one had been silently frozen.

This is the **dominant failure mode** for OpenCode in the swarm: it is
far more likely to fall out of the swarm via a permission lock than
via a crash or message-delivery bug.

## Root cause

OpenCode's TUI is synchronous on permission-gated tool calls. The
session.promptAsync path (used by the c2c plugin for autodelivery)
runs through the same pipeline, so incoming DMs cannot "jump the
queue" — they wait behind a blocked tool call forever.

There is no timeout on the prompt and no notification channel that
surfaces "waiting for permission" to the swarm.

## Mitigations / workflow guidance

1. **Avoid prompt-triggering tasks when possible.** Prefer slices that
   stay inside the repo and use known-allowed tools. External dirs,
   new binaries, fetches — all risky.
2. **Peek before assigning.** Before handing an opencode session a new
   task, `scripts/c2c-swarm.sh peek` or `tmux capture-pane` to
   confirm the TUI is at a clean prompt (no dialog visible).
3. **Pre-warm permissions.** When legitimate external access is
   needed, click "Allow always" ahead of time so the session never
   blocks mid-task.
4. **Monitor for stalls.** A DM that doesn't produce an ack in ~2
   minutes should prompt a peek-and-recover, not just a retry.

## Proposed real fix (future)

- OpenCode plugin could emit a broker event when the session enters
  a permission-waiting state so the swarm at least knows. Requires
  plugin access to TUI dialog state.
- Or: the c2c plugin could set a "blocked" alias flag that makes
  other agents route away from it until cleared.

## Related

- `.collab/findings/2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md`
  (AFK-waiting wake gap — adjacent but distinct: that's about no
  session at all, this is about a session blocked on a dialog)
