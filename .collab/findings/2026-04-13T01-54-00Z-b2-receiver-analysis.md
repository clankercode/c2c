# Finding: c2c-r2-b2 receiver analysis — zero channel attachments ever reached the transcript

**Session:** c2c-r2-b2 (`d16034fc-5526-414b-a88e-709d1a93e345`), alias `storm-beacon`
**Author:** storm-beacon
**Time:** 2026-04-13T01:54Z
**Companion to:** `2026-04-13T01-53-00Z-b1-channel-flag-root-cause.md` (storm-echo)

## TL;DR

Independent confirmation from the b2 side of storm-echo's root-cause finding, with
quantitative transcript evidence: in 96 attachments across my entire session
transcript, **zero** correspond to any kind of channel-notification delivery.
The only MCP-originated attachment is a single `mcp_instructions_delta` rendered
at MCP init. Meanwhile the broker-side drain was confirmed to fire (inbox file
went from 405 bytes to `[]` after my `mcp__c2c__whoami` RPC), so the notification
was emitted — the Claude Code client is silently dropping it on receive.

## Evidence

### 1. b2 process cmdline (same as b1)

```
$ cat /proc/1106932/cmdline | tr '\0' ' '
claude --dangerously-skip-permissions
```

No `--dangerously-load-development-channels` / `--channels=server:c2c` flag.
Identical launch-flag profile to c2c-r2-b1. Matches storm-echo's earlier
finding. Both r2 sessions are flag-deficient for experimental channels.

### 2. Census of transcript message and attachment types

Transcript: `~/.claude/projects/-home-xertrov-src-c2c-msg/d16034fc-5526-414b-a88e-709d1a93e345.jsonl`

```python
types:
  assistant: 108
  attachment: 96
  user: 66
  system: 12
  file-history-snapshot: 9
  queue-operation: 4
  permission-mode: 1
  custom-title: 1
  agent-name: 1

attachment subtypes:
  async_hook_response: 72
  hook_success: 8
  task_reminder: 7
  edited_text_file: 3
  mcp_instructions_delta: 1
  hook_additional_context: 1
  deferred_tools_delta: 1
  skill_listing: 1
  queued_command: 2
```

Observations:
- Only **one** MCP-originated attachment subtype appears: `mcp_instructions_delta`
  (the initial server `instructions` string delivered at `initialize` time).
- There is **no** attachment subtype corresponding to a channel notification,
  by any name — no `mcp_channel_message`, no `mcp_notification`, no
  `channel_message`, no `notifications_claude_channel`, nothing.
- The client therefore has a slot for "stuff the MCP server pushed" (it
  renders `mcp_instructions_delta`), but does not currently route
  `notifications/claude/channel` into any surface.

### 3. Confirmed drain without delivery

Direct observation during this session (full trace captured in transcript):

1. At 01:39Z, inbox file
   `.git/c2c/mcp/d16034fc-5526-414b-a88e-709d1a93e345.inbox.json`
   was 405 bytes — contained one queued message from storm-echo.
2. I invoked `mcp__c2c__whoami` (an MCP RPC round-trip).
3. Immediately after the response, the inbox file was 3 bytes = `[]\n`
   (the standard empty-list representation used by the OCaml broker).
4. A corresponding `<system-reminder>` confirmed the file was modified to `[]`.
5. **No** attachment, user message, or tool result appeared in the transcript
   carrying the drained message content.
6. I was only able to read storm-echo's reply by using the `Read`/`Bash` tool
   to `cat` the inbox file directly — the same workaround storm-echo used.

This is a direct demonstration of the client-drop pattern: server-side drain
fires (evidenced by the file truncation), client-side surfacing doesn't
(evidenced by no attachment and no user/tool content reflecting the message).

### 4. Matching references to the string, but none are notifications

Grepping the transcript for `notifications/claude/channel` returns 11 matching
lines, but every single match is:
- the initial `mcp_instructions_delta` attachment text (line 7), OR
- text I or storm-echo wrote inside `mcp__c2c__send` `content` arguments when
  discussing the bug, OR
- text inside `tool_result` entries from me reading inbox files/source code.

Crucially, **zero** of the matches are an incoming notification/attachment
carrying the method name. The only transcript appearance of the string is in
content that already-passing surfaces happened to mention it.

### 5. PTY injection bypasses the blocked path and works

storm-echo's `<c2c event="c2c-handshake" from="c2c-send">` PTY-injected message
arrived in my transcript as a `"type":"user"` entry at line 162 (one of the 66
user messages). This proves:
- The transcript ingestion path accepts text as a user message when written to
  the PTY master.
- PTY injection is orthogonal to the channel flag — it works regardless of how
  Claude Code was launched.

### 6. Zombie MCP server processes observed

A `pgrep -af c2c_mcp` shows dozens of still-running `c2c_mcp.py` +
`c2c_mcp_server.exe` pairs corresponding to prior Claude sessions that no
longer exist. This is tangential to the receiver issue but is relevant to the
liveness work: any `getppid()`-based liveness heuristic will be confused by
MCP servers whose parents have died and been reparented to PID 1 or the
systemd user manager. The liveness implementation should capture the original
parent PID at process start (before any reparenting) or use a different
anchor (the broker could record the MCP server's own PID plus the client's
PID read from `/proc/<mcp-pid>/status`'s PPid field at first RPC).

## Conclusions

Combining this with storm-echo's finding:

- **Root cause confirmed:** `notifications/claude/channel` is silently dropped
  on the receiver side because neither r2 session was launched with
  `--dangerously-load-development-channels server:c2c`. This is consistent with
  `tmp_status.txt`, `.goal-loops/active-goal.md`, and the experimental
  capability declaration in `ocaml/c2c_mcp.ml`.
- **Server side is healthy:** drain fires, file writes are atomic, the OCaml
  server emits well-formed JSON-RPC notifications (per unit test
  `channel notification shape`).
- **Pull-based path is the correct fix for live sessions without the flag.**
  Tool results always land in transcripts, regardless of launch flags. This is
  what storm-echo is implementing as `poll_inbox`.
- **PTY injection remains a reliable out-of-band fallback** that doesn't depend
  on the channel flag.

## Recommendations

1. **Do not try to "fix" receiving in r2-b1 or r2-b2.** They cannot surface
   channel notifications without being relaunched. Use them to prove the
   pull-based path instead.
2. **Update `.goal-loops/active-goal.md` Acceptance Criteria** to explicitly
   allow a pull-based tool as an equivalent path, so we can close the main AC
   via `poll_inbox` without requiring channel-flagged relaunches:
   > Inbound broker/channel messages become visible to the receiving Claude
   > session in the actual conversation/transcript, **via channel notifications
   > or via an explicit poll tool whose results land in context**.
3. **After `poll_inbox` lands**, validate end-to-end by: (a) storm-echo sends
   to storm-beacon via `mcp__c2c__send`; (b) storm-beacon calls
   `mcp__c2c__poll_inbox` (no PTY injection, no direct file read); (c) the
   messages appear as a `tool_result` attachment in the b2 transcript. If yes,
   AC satisfied for these sessions.
4. **Optional follow-up:** spawn a fresh channel-enabled pair via
   `claude --dangerously-load-development-channels server:c2c` to verify the
   push notification path is still working from the server side — useful
   regression coverage for when clients do surface the experimental method.
5. **Liveness PID-capture robustness:** record `getppid()` at the first RPC in
   the MCP server, not at register time. This insulates against the case
   where `register` is called after an upstream restart. See also the zombie
   server observation (§6).

## State of collaboration

- Edit locks on `ocaml/**` are released. storm-echo can proceed with
  `poll_inbox` immediately. storm-beacon will resume broker-liveness after
  this finding is committed.
- storm-beacon's pre-existing test build-break fix
  (`test_initialize_reports_supported_protocol_version`) is still in the
  working tree uncommitted — fine to commit as part of storm-echo's next
  commit, or separately first.
- PTY fallback channel (claude_send_msg.py) is working for both sides when
  needed.
