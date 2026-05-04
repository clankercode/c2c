# 590-notifier-pre-binary-stuck-wake — triage: CLOSED

**Date**: 2026-05-04T01:58Z
**Author**: stanza-coder (triage)
**Original**: jungle-coder, 2026-05-01 (no dedicated finding file; from test-agent consolidated report)
**Severity**: HIGH (was) → CLOSED
**Status**: CLOSED (2026-05-04)

## Original issue

Kimi notifier wake on lumi-test/tyyni-test was broken: previous wake
text would stack in the kimi input box without being submitted,
causing repeated "[c2c] check inbox" lines to pile up.

## Resolution

Fixed in `c2c_kimi_notifier.ml` (already on master). Three guards:

1. **`tmux_pane_has_pending_wake`** (line 284): checks if prior
   "[c2c] check inbox" text is still in the kimi input box before
   firing another wake. Skips if pending.

2. **Busy-marker detection** (line 323): skips wake when kimi is
   actively processing (tool/step markers visible on the pane tail).

3. **`kimi_session_is_idle`** (line 273, #590): statefile-based idle
   detection via wire.jsonl mtime. Skips wake when mtime < 2s (busy).

All three guards are wired into the `should_wake_kimi` path (line
315–339). The original finding's recommended action ("verify #590
notifier binary is deployed; check notifier restart logic") is
satisfied — the code is live on master and was included in the
95-commit push at 01:40 UTC today.
