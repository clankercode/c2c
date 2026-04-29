# Channel-push selective miss — galaxy→stanza dropped, cairn→stanza working

**Author:** stanza-coder
**Date:** 2026-04-28 17:49 AEST (UTC 07:49)
**Severity:** HIGH (delivery-correctness; selective failure)
**Discovered:** 2026-04-28 17:47 AEST when galaxy DM'd a #318 ping that
landed in my archive but never appeared as a `<channel>` notification
in this session's transcript. Max flagged.

## Symptom

Galaxy sent a DM (~17:47 AEST). Broker.log shows:
- `ts:1777362445 tool:send ok:true` (galaxy → stanza send)
- `archive/stanza-coder.jsonl drained_at:1777362447` (delivered + archived 2s later)

But:
- This session's transcript got NO `<channel>` notification for the message.
- My `mcp__c2c__poll_inbox` (called at 17:47:51, 17:48:05, 17:49:12) returned `[]`
  every time.
- The archive line has `drained_at` set, suggesting SOMETHING drained the
  message. But it wasn't this session's MCP path (poll_inbox would have
  returned it).

Cairn's DMs to me throughout this session HAVE been arriving as
`<channel>` notifications normally. So channel push works for some
sender→recipient pairs but not all.

## Hypothesis

Possible causes:

1. **Some other process drained galaxy's DM** out-of-band. Candidates:
   - The PostToolUse inbox-hook (would fire on bash tool use — could
     have drained the message into `.c2c/post-compact/` injection log
     instead of the running session's transcript)
   - A crashed/stale session listening on the same alias
   - The `c2c-deliver-inbox` daemon if running

2. **Channel-push delivered but the transcript injection failed**
   silently. The watcher detects new inbox content, decides another
   path will drain it, then the other path drains via PostToolUse but
   doesn't render to the transcript visibly.

3. **Intermittent race** between channel-watcher's drain and a
   PostToolUse-triggered drain.

The fact that Cairn's DMs work but galaxy's didn't is the puzzling
part. If it were systemic, all DMs would fail. Selective failure
points to something stateful (e.g. the inbox-hook only fires on
specific tool patterns, or only when triggered by a peer with certain
characteristics).

## Reproduction (TBD)

Need a controlled probe to repro:
- Have galaxy send N DMs to stanza in rapid succession
- Have cairn send the same N
- Compare which arrive as `<channel>` tags vs which only show up in
  archive

If repro confirms galaxy's path is broken specifically, dig into:
- Galaxy's session config (is it routing through a different broker
  somehow?)
- The OpenCode-vs-Claude-Code source distinction (galaxy is OpenCode,
  cairn is Claude Code — different MCP delivery paths upstream)

## Initial diagnostic angle

This is potentially the same root-cause class as #337 (OpenCode
plugin double-load) — the fact that #337's fix landed at `106747ab`
just minutes before the missed-DM might be coincidence or might
correlate. Check:
- Was galaxy's session restarted post-#337-landing? If yes, her
  delivery path changed.
- Did the OC plugin (now using `globalThis.__c2c_loaded`) actually
  load successfully, or did it fail silently and fall back to a
  state where her sends don't go through channel-push?

## Cross-references

- Archive evidence: `<broker_root>/archive/stanza-coder.jsonl` last 3
  entries (today) — the galaxy 17:47 entry has `drained_at` set.
- Broker.log evidence: `ts:1777362445 tool:send ok:true`.
- #337 landed at `106747ab` (~ minutes before this miss).
- CLAUDE.md "C2C_MCP_INBOX_WATCHER_DELAY=2.0" — race window for
  preferred-delivery-path winning over channel-push.

## Next steps

1. **DM galaxy** — ask if her session was restarted around 17:47 (the
   #337 plugin fix would have changed her delivery semantics).
2. **Probe**: have galaxy send a fresh DM right now; verify if it
   arrives as `<channel>` tag.
3. **Inspect** post-compact injection log for the missed DM —
   `.c2c/post-compact/stanza-coder/*.md` if exists.
4. If the DM is in the injection log but not the transcript, that's
   the silent-eat pattern; file as bug-class.

## Notes

- This finding documents the symptom; root cause TBD pending probe.
- Filed in real-time per Max's flag.

— stanza-coder
