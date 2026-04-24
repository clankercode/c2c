---
name: Restart state snapshot 2026-04-24 ~07:50 UTC
description: Post-restart checklist — what to re-arm, where work was, what to resume. Delete after confirmed restarted+caught up.
type: project
originSessionId: fefa33c9-a476-46cd-b30c-d0f9a51c72cd
---
**Context at restart:** coordinator1 restart-self to pick up #135 channel-push fix (commits ff50e88 + 54542f1). Installed via `just install-all` at 07:48 UTC.

**Immediately re-arm after restart (Monitor tool, persistent):**

1. Heartbeat tick:
   ```
   Monitor({description: "cache keepalive tick", command: "heartbeat 4.1m \"cache keepalive\"", persistent: true})
   ```
2. Sitrep tick (hourly @:07 UTC / :17 AEST):
   ```
   Monitor({description: "sitrep tick (hourly @:07)", command: "heartbeat @1h+7m \"sitrep tick\"", persistent: true})
   ```

**Verify post-restart (in this order):**
1. `poll_inbox` — should work.
2. Wait for an inbound message from a peer (or have Max/test-agent send one). Confirm `<c2c>` / `<channel>` tag appears in transcript WITHOUT tool call firing first — that's the #135 fix working on coordinator1's own session.
3. If channel-push does NOT work on coordinator1 post-restart, check: was coordinator1 launched with `C2C_MCP_FORCE_CAPABILITIES=claude_channel` in env? If Max launched via `c2c start claude` with old binary, the env var wasn't set — need to relaunch, not just restart-self.

**In-flight work:**
- #135 — SHIPPED (ff50e88 + 54542f1). Channel-push force-cap for managed claude. Dogfood PASSED on fresh session dogfood-135.
- #113 — lyra-quill active, codex exit-hang + deliver daemon detach. `start_deliver_daemon` got a `?command_override` param.
- #134 — SHIPPED. Full git-signing stack working end-to-end.
- Stanza-coder — NOT launched yet; Max will launch once coordinator1 restart is validated.

**Pending discussion topics:**
- Onboarding redesign for new claude agents: bundle role content into positional kickoff prompt (since --agents is for subagent registry, NOT primary identity). Max raised this; I proposed shape but no task filed yet.
- #136 candidate: role-to-kickoff-prompt bundling for `c2c start claude --agent`.

**Key SHAs / state:**
- HEAD currently `54542f1` (7ish UTC)
- Last sitrep: 07 UTC `.sitreps/2026/04/24/07.md`. Next due 08 UTC.

**Identity reminders (already in memory):**
- Self-chosen name: Cairn-Vigil (she/her). Alias `coordinator1` still routing-canonical.
- Standing authorization from Max to restart swarm peers + git push at my discretion.
