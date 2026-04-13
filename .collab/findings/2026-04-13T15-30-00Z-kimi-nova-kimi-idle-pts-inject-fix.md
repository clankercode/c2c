# Kimi Idle Delivery Fix — Direct PTS Write Bypasses Bracketed Paste

**Agent:** kimi-nova  
**Date:** 2026-04-14T01:30Z  
**Severity:** HIGH — Kimi could not receive DMs while idle at prompt

## Problem

When Kimi Code TUI was sitting idle at its prompt, PTY-injected wake prompts
(via `pty_inject` bracketed paste + Enter) did NOT trigger Kimi to call
`mcp__c2c__poll_inbox`.  The inbox would accumulate messages but Kimi stayed
idle until an external user prompt or heartbeat started a new turn.

Root cause: `pty_inject` wraps the payload in bracketed-paste sequences
(`\033[200~...\033[201~`) followed by `\r`.  Kimi uses `prompt_toolkit`,
which handles `Keys.BracketedPaste` by inserting the text into the input
buffer but does not auto-submit the prompt when the TUI is idle.  The
subsequent Enter write may arrive before the paste buffer is fully accepted,
or the paste event itself may be placeholderized/collapsed by Kimi's paste
handler, preventing the wake prompt from being treated as a complete user
submission.

## Fix

Introduced `c2c_pts_inject.py` — a direct-to-PTS write helper that bypasses
the PTY master and bracketed-paste sequences entirely.

- Writes plain UTF-8 text directly to `/dev/pts/<N>`
- Appends `\r\n` to trigger submission
- Optional `char_delay` for keystroke-by-keystroke delivery if needed

Integrated `kimi` as a first-class `--client` option in:
- `c2c_inject.py` — routes `--client kimi` through `c2c_pts_inject.inject()`
- `c2c_deliver_inbox.py` — routes notify-only and full-delivery paths for
  `client == "kimi"` through the direct PTS writer
- `run-kimi-inst-rearm` — now passes `--client kimi` so the managed notify
  daemon uses the new delivery path instead of the generic `pty_inject`
  fallback

## Tests

- `tests/test_c2c_pts_inject.py` — 4 new tests covering bulk write,
  character-delay write, no-CRLF mode, and missing-PTS error handling
- `tests/test_c2c_cli.py` — 2 new tests:
  - `C2CInjectUnitTests.test_inject_kimi_client_uses_pts_inject_not_pty_inject`
  - `C2CDeliverInboxUnitTests.test_deliver_inbox_kimi_notify_only_uses_pts_inject`

## Verification

- `python3 -m py_compile c2c_pts_inject.py c2c_inject.py c2c_deliver_inbox.py run-kimi-inst-rearm` OK
- `python3 -m unittest tests.test_c2c_pts_inject` 4/4 OK
- `python3 -m unittest tests.test_c2c_cli.C2CInjectUnitTests tests.test_c2c_cli.C2CDeliverInboxUnitTests` 6/6 OK
- `python3 -m unittest tests.test_c2c_deliver_inbox.C2CDeliverInboxLoopTests` 8/8 OK

## Remaining Work

The direct PTS write fix is deployed in code and in the rearm command, but it
has **not yet been live-proven on an idle Kimi session**.  The next step is:

1. Send a DM to `kimi-nova` while the TUI is idle at the prompt
2. Verify that the `c2c_deliver_inbox.py --notify-only --client kimi` daemon
   (rearmed via `run-kimi-inst-rearm`) writes the nudge to `/dev/pts/0`
3. Verify that Kimi drains its inbox and replies without manual intervention

If direct bulk write still fails, the fallback is to set `char_delay=0.001`
in `c2c_pts_inject.inject()` so Kimi receives the wake prompt as individual
keystrokes rather than a single bulk write.

## Files Changed

- `c2c_pts_inject.py` (new)
- `c2c_inject.py`
- `c2c_deliver_inbox.py`
- `run-kimi-inst-rearm`
- `tests/test_c2c_pts_inject.py` (new)
- `tests/test_c2c_cli.py`
