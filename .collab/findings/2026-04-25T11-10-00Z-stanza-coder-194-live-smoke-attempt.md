# #194 Live Smoke Attempt — Codex Permission Forwarding

**Date:** 2026-04-25T11:10:00Z
**Reporter:** stanza-coder
**Status:** Partial — key gap found

## What I tried

Spun up `smoke-codex` via `c2c start codex -n smoke-codex` in a new tmux
window (session 0, window 0). Sent a bash prompt to trigger a permission
request. Observed the session via `tmux capture-pane`.

## What I found

`c2c instances` showed:

```
smoke-codex  codex  running  unavailable (pid 1372638) [0:0.1]
```

`unavailable` means no deliver daemon was started for this session. No
deliver daemon = no permission forwarding = the #194 fix cannot be exercised
through this path.

More importantly: **the #194 fix applies to `codex-headless` mode, not
interactive codex**. The bridge FIFO mechanism (`--server-request-responses-fd
7`, `bridge-responses.fifo`) is only wired in the `start_codex_headless`
path in `c2c_start.ml`. A regular `c2c start codex` session uses the xml_fd
delivery path (like Lyra-Quill-X does), which doesn't go through
`codex-turn-start-bridge` at all.

## Impact on #194

The code fix is correct — the three bugs are real and the patches are right —
but the in-wild verification needs a `codex-headless` instance with:
1. A running deliver daemon with `--response-fifo` passed
2. The bridge FIFOs created
3. A prompt that actually triggers a permission request through the headless bridge

## Recommendation

Next live smoke should target `codex-headless`, not interactive codex.
Check if any existing stopped `codex-headless-probe` instance can be
revived with `c2c start codex-headless -n headless-perm-smoke` in a
proper tmux pane. Then verify the permission event appears in the deliver
daemon logs and the decision is written back via the responses FIFO.

## Severity

Low — the fix is code-correct and unit-tested. The live smoke gap is a
"we haven't seen it work end-to-end in the wild" concern, not an indication
that the fix is wrong. The 7<> FIFO open semantics are correct for Linux.
