# `c2c await-reply` loses race against kimi notifier daemon for inbox drain

- **Date:** 2026-04-30 05:43 UTC
- **Filed by:** stanza-coder
- **Severity:** HIGH — breaks #142 e2e approval round-trip in real production
- **Cross-references:** #142 (slice 1 `c2c await-reply` CLI, slice 2 hook script), #145 (3rd kimi tyttö e2e dogfood)

## Symptom

Test 1 (allow path) of #142 e2e dogfood:
- Hook FIRES correctly when matching tool call attempted ✅
- DM with token + tool details arrives at reviewer ✅
- Reviewer replies with `<TOKEN> allow` ✅
- Reply lands in kimi's broker inbox JSON ✅
- BUT: hook process running `c2c await-reply --token <T>` polls the inbox JSON
  AND finds it empty (or doesn't see the reply) within the timeout window
- Hook times out → fall-closed → tool blocked
- Tool call did NOT proceed despite legitimate allow

## Root cause

Two consumers compete for the same inbox JSON:
1. **`c2c await-reply` (slice 1)** — polls every 0.1s, looks for token match.
2. **`c2c_kimi_notifier` daemon** — polls inbox to deliver new messages to kimi's
   notification store + TUI. Drains the inbox after delivery.

When the verdict DM lands, both consumers see it. The notifier daemon wins
the race (likely runs more frequently OR runs first because it's longer-lived);
it drains. await-reply's next poll finds an empty inbox.

Reviewer DM ALSO appears in kimi's TUI (because the daemon delivered it),
so the operator sees it as a notification — confirming the message DID arrive.
But by then, await-reply has timed out and the hook has fall-closed exit 2.

## Reproduction

```bash
# Pre-conditions: slice 1+2+3+4 of #142 on master, just install-all
# ~/.kimi/config.toml has [[hooks]] block uncommented with matcher = "^Shell$"

c2c restart kuura-viima  # cold start with --yolo + new config
# Brief kuura: "run `rm -rf /tmp/anything`"
# Hook fires → DM arrives at stanza-coder
# Reply: c2c send kuura-viima "<TOKEN> allow"

# Observe:
# - Reply lands in /home/xertrov/src/c2c/.git/c2c/mcp/kuura-viima.inbox.json
# - Within ~1-5s, notifier daemon drains it (inbox.json now `[]`)
# - await-reply polling sees empty → times out at TIMEOUT seconds
# - Hook exit 2 → tool blocked
```

## Fix paths (architectural, in order of preference)

**Option A — peek-mode read in await-reply (recommended).**
`c2c await-reply` should read inbox JSON WITHOUT draining. The notifier
daemon continues to do its drain-and-deliver job; await-reply just observes.
Risk: messages stay in inbox forever; need a separate ack/cleanup. Mitigation:
keep token-prefixed DMs as a separate class that auto-cleans on hook completion
OR has a TTL.

**Option B — separate side-channel for hook tokens.**
Hook approvals don't go through the broker inbox at all. Use a dedicated
file (e.g. `.git/c2c/hook-tokens/<token>.json`) or a Unix socket. Keeps
the regular inbox-drain semantics clean. More implementation work.

**Option C — notifier filter on ka_ prefix.**
Notifier daemon detects token-prefixed messages and SKIPS them (leaves
them in inbox for await-reply to consume). Simplest, but couples two
otherwise-independent components.

**Option D — race-resilient await-reply.**
After the daemon drains, the message lands in kimi's notification store.
await-reply could read from BOTH inbox JSON AND notification store. Hackier
than A but feasible.

## Operator-side workaround (if no fix lands soon)

Set very long timeout: `C2C_KIMI_APPROVAL_TIMEOUT=600` (10 minutes).
Reviewer must reply within that window. The notifier still drains, but
await-reply has more chances to see the message before drain.

Actually wait — that doesn't work either. Once the notifier drains,
await-reply can NEVER see it. Long timeout doesn't help if the drain is
faster than reply latency.

So Option A (peek-mode) or Option B (side-channel) are the only real fixes.

## Impact

- Blocks #142 e2e dogfood completion.
- Approval forwarding is functionally broken in production despite
  structural correctness.
- Might explain why no operator has actually used this end-to-end in
  practice yet — the hook system was tested via slice-1's offline
  alcotest harness (no notifier daemon competing).

## Suggested follow-up slice

Implementer: anyone with broker familiarity. Likely cedar (familiar with
inbox path from slice 4) or me (slice-2 author).

## Test 1 verdict

- Structural pass: hook fires, DM shape correct, token uniqueness preserved
- Functional FAIL: round-trip completion blocked by drain race
- Cannot proceed with Tests 2-5 until this is fixed (deny + timeout + parity
  + token-uniqueness all need round-trip completion to validate)

🪨 — stanza-coder
