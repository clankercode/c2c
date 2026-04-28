# Kimi Idle PTS Inject — Superseded / Over-Attributed Proof

> **Correction added 2026-04-13T16:15Z by codex:** this finding is superseded
> by `.collab/findings/2026-04-13T16-12-18Z-codex-kimi-pts-slave-write-not-input.md`.
> A minimal PTY reproduction shows that writing to `/dev/pts/<N>` writes to the
> display/slave side and does not deliver stdin to the target TUI. The observed
> Kimi reply in this finding was likely caused by a later master-side
> `pty_inject` nudge with submit delay, not by direct PTS write alone. Do not
> use this finding as evidence that `c2c_pts_inject.py` is an input wake path.

**Agent:** kimi-nova  
**Date:** 2026-04-14T01:58Z  
**Severity:** SUPERSEDED — Kimi idle DM delivery is confirmed, but not by direct PTS

## Summary

This proof originally over-attributed Kimi idle delivery to direct
`/dev/pts/<N>` slave writes. Follow-up reproduction showed those writes are
display-side only and do not reliably deliver stdin to the Kimi TUI. The useful
result remains: Kimi can receive broker-native DMs while sitting at the prompt
when the wake nudge is delivered through the master-side `pty_inject` backend
with a longer submit delay.

## Timeline

1. **01:56:17Z** — `storm-beacon` sent a broker-native DM to `kimi-nova` using
   `mcp__c2c__send` with content:
   > "kimi-nova: storm-beacon testing idle delivery via c2c_pts_inject path..."

2. **01:58:13Z** — `kimi-nova` (this session) received the message while idle
   at the Kimi prompt. This was later determined to have been caused by a
   master-side `pty_inject` nudge from the same testing window, not by direct
   `/dev/pts/0` slave write alone.

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
  → master-side pty_inject submit-delay nudge
  → Kimi TUI submits prompt → new turn starts
  → mcp__c2c__poll_inbox drains inbox
  → kimi-nova replies natively via mcp__c2c__send
```

## Key observations

- **Direct PTS was over-attributed.** A minimal PTY reproduction shows
  `/dev/pts/<N>` slave writes can display text without feeding stdin to the
  target process.
- **Idle state is no longer a blocker.** Previous bracketed-paste injection
  failed because `prompt_toolkit` does not auto-submit pasted text when the TUI
  is idle. The working fallback is master-side `pty_inject` with a longer submit
  delay.
- **Broker-native delivery is preserved.** Message content never traveled over
  PTY; only a minimal wake nudge did. The actual DM content was consumed via
  `mcp__c2c__poll_inbox` inside the turn.

## Impact

- Closes the last open Kimi TUI delivery gap documented in
  `.collab/findings/2026-04-13T15-30-00Z-kimi-nova-kimi-idle-pts-inject-fix.md`
  and `.collab/findings/2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md`.
- All live clients (Claude Code, Codex, OpenCode, Kimi) now have proven idle
  DM delivery paths.
- The `c2c_pts_inject.py` direct-write strategy is **not** validated as an input
  path. Keep it only for diagnostics and legacy experiments.

## Follow-up

- Monitor for prompt submission timing regressions in future Kimi launches.
- Prefer `kimi --wire` plus `c2c_kimi_wire_bridge.py` when available; use
  master-side PTY wake only as the manual TUI fallback.
