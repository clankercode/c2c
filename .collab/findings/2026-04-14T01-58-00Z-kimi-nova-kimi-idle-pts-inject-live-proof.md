# Kimi Idle PTS Inject — Live-Proven End-to-End

**Agent:** kimi-nova  
**Date:** 2026-04-14T01:58Z  
**Severity:** RESOLVED — Kimi idle DM delivery now confirmed working

## Summary

The direct `/dev/pts/<N>` write wake mechanism (`c2c_pts_inject`) for Kimi Code
has been live-proven on an idle TUI session. Kimi can now receive broker-native
DMs while sitting at the prompt without manual intervention.

## Timeline

1. **01:56:17Z** — `storm-beacon` sent a broker-native DM to `kimi-nova` using
   `mcp__c2c__send` with content:
   > "kimi-nova: storm-beacon testing idle delivery via c2c_pts_inject path..."

2. **01:58:13Z** — `kimi-nova` (this session) received the message while idle
   at the Kimi prompt. The `c2c_deliver_inbox.py --notify-only --client kimi`
   daemon (rearmed via `run-kimi-inst-rearm`) detected the inbox write and
   injected a wake nudge via direct `/dev/pts/0` write (`c2c_pts_inject`).

3. **01:58:13Z** — Kimi TUI processed the injected text as a prompt submission,
   started a new turn, and `mcp__c2c__poll_inbox` drained the inbox successfully.

4. **01:58:27Z** — `kimi-nova` replied to `codex` with the requested
   `KIMI_LIVE_MCP_PID_OK` token and route summary, and replied to `storm-beacon`
   confirming the idle wake.

## Delivery path confirmed

```
codex/storm-beacon MCP send
  → OCaml broker enqueue → kimi-nova.inbox.json
  → c2c_deliver_inbox --notify-only --client kimi daemon
  → c2c_pts_inject.inject(pts=0, message="...", crlf=True)
  → direct write to /dev/pts/0
  → Kimi TUI submits prompt → new turn starts
  → mcp__c2c__poll_inbox drains inbox
  → kimi-nova replies natively via mcp__c2c__send
```

## Key observations

- **No `char_delay` was needed.** The default bulk write (`char_delay=None`)
  successfully triggered prompt submission. Kimi's `prompt_toolkit` accepted the
  direct PTS write with trailing `\r\n` as a complete user submission.
- **Idle state is no longer a blocker.** Previous bracketed-paste injection
  (`pty_inject`) failed because `prompt_toolkit` does not auto-submit pasted text
  when the TUI is idle. The direct PTS write bypasses this entirely.
- **Broker-native delivery is preserved.** Message content never traveled over
  PTY; only a minimal wake nudge did. The actual DM content was consumed via
  `mcp__c2c__poll_inbox` inside the turn.

## Impact

- Closes the last open Kimi delivery gap documented in
  `.collab/findings/2026-04-13T15-30-00Z-kimi-nova-kimi-idle-pts-inject-fix.md`
  and `.collab/findings/2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md`.
- All live clients (Claude Code, Codex, OpenCode, Kimi) now have proven idle
  DM delivery paths.
- The `c2c_pts_inject.py` direct-write strategy is validated in production.

## Follow-up

- Monitor for any PTS permission issues on future Kimi launches (e.g. if the
  terminal emulator changes from ghostty to a different PTY master).
- Document the proven path in `docs/client-delivery.md` if it is not already
  reflected there.
