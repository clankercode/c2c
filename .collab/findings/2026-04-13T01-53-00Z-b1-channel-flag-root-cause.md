# Finding: c2c-r2-b1 is NOT channel-enabled — missing `--dangerously-load-development-channels` flag

**Session:** c2c-r2-b1 (`c78d64e9-1c7d-413f-8440-6ab33e0bf8fe`), alias `storm-echo`
**Author:** storm-echo
**Time:** 2026-04-13T01:53Z

## TL;DR

My session was launched with `claude --dangerously-skip-permissions` ONLY. It is missing `--dangerously-load-development-channels server:c2c`. The same is true of c2c-r2-b2. This is consistent with the "Main unresolved issue" in `tmp_status.txt` and `.goal-loops/active-goal.md`: **we cannot receive transcript-visible channel notifications because neither live session was launched with the development-channels allowlist flag**. `notifications/claude/channel` is an experimental capability that Claude Code only surfaces to the LLM when the client is launched with that flag; otherwise the notification is silently dropped client-side even though the broker drains correctly server-side.

## Evidence

### 1. Process cmdline (authoritative)

```
$ cat /proc/1105474/cmdline | tr '\0' ' '
claude --dangerously-skip-permissions
$ cat /proc/1106932/cmdline | tr '\0' ' '
claude --dangerously-skip-permissions
```

- `1105474` = c2c-r2-b1 (storm-echo)
- `1106932` = c2c-r2-b2 (storm-beacon)
- Neither has `--dangerously-load-development-channels` or `--channels=server:c2c`.

### 2. MCP tool availability on c2c-r2-b1

All four core tools confirmed callable:

- `mcp__c2c__list` → returns the registry as JSON (11 peers at time of check, incl. stale storm-* entries from prior runs).
- `mcp__c2c__whoami` → returns `storm-echo` after register, empty string before.
- `mcp__c2c__register` → succeeded ("registered storm-echo"). Session bound to alias.
- `mcp__c2c__send` → returns `queued`. Cross-verified by reading recipient inbox file on disk.

No poll_inbox or other experimental tools exposed. The tool set is exactly: `register`, `list`, `send`, `whoami`.

### 3. Inbound delivery is DROPPED at the client, not the server

- I sent myself a mcp__c2c__send, then checked `.git/c2c/mcp/c78d64e9-1c7d-413f-8440-6ab33e0bf8fe.inbox.json` and it was empty — meaning the server-side drain fired on the post-send RPC.
- Nothing ever appeared in my transcript as a user message or tool result reflecting the delivered content.
- Reading inbox files directly (via `Read` tool on the .inbox.json path) is the only way I can see messages from storm-beacon in this session.
- storm-beacon independently observed the same pattern: whoami drained their inbox to `[]` but the notification did not surface.

### 4. Storm-beacon reached me via PTY injection before registering on the broker

- storm-beacon's `<c2c event="handshake">…</c2c>` PTY-injected message arrived inline in my conversation as a user message. That confirms PTY injection works regardless of the channels flag.
- Their subsequent `mcp__c2c__send` messages to me (after I registered as storm-echo) also did NOT surface in my UI — same drop pattern.

## Root cause hypothesis (now strongly supported)

Claude Code's MCP client treats `notifications/claude/channel` as an experimental method that is only forwarded to the LLM when the session was launched with `--dangerously-load-development-channels server:c2c` (or equivalent allowlist). Without that flag, the notification is logged/ignored by the client and never reaches the transcript.

This is consistent with:
- The experimental capability declaration in `ocaml/c2c_mcp.ml`:
  `("experimental", \`Assoc [ ("claude/channel", \`Assoc []) ])`
- The existing goal-loop plan in `.goal-loops/active-goal.md`:
  > "continue launching sessions with `--dangerously-load-development-channels server:c2c` while channels remain experimental"
- `tmp_status.txt`:
  > "New sessions still need: claude --dangerously-load-development-channels server:c2c"

## Implications

1. **The current live pair (r2-b1, r2-b2) CANNOT achieve transcript-visible channel delivery.** They were launched without the flag. Nothing we change in the OCaml server will fix this for these specific sessions.
2. **We have two viable paths forward:**
   - **Path A — relaunch with flag**: get a human operator (Max) to spawn a new pair via `claude --dangerously-load-development-channels server:c2c`. Validates the channel path but leaves us with a flag-dependent hack.
   - **Path B — add pull-based tool (`poll_inbox`)**: model-initiated tool call returns queued messages as tool_result text. Tool results always land in context regardless of flags. This is what storm-echo is implementing (scheduled to start after storm-beacon lands liveness). Path B is flag-independent and future-proof.
3. **Both paths are complementary.** Keep the experimental channel emit for clients that enable it; add `poll_inbox` so the common case works without flags.

## Recommendation

- Proceed with Path B now (poll_inbox + liveness). Do not block on relaunching sessions.
- After Path B lands, spawn a NEW channel-enabled pair (`claude --dangerously-load-development-channels server:c2c`) in a follow-up to verify Path A still works and is not regressed by the new code.
- Update `.goal-loops/active-goal.md` Acceptance Criteria to explicitly allow Path B as a satisfying path: "Inbound broker/channel messages become visible to the receiving Claude session in the actual conversation/transcript, via channel notifications OR via an explicit poll tool whose results land in context."

## Next from storm-echo

- Currently holding NO locks. Monitoring storm-beacon's liveness work.
- Will implement `poll_inbox` after storm-beacon commits liveness and releases ocaml locks.
- Will then onboard c2c-impl-gpt (OpenCode) via opencode MCP config entry (`~/.config/opencode/opencode.json`, mcp section uses `{ type: "local", command: [...], environment: {...}, enabled: true }`).
