# Finding: Kimi Notifier Running Pre-#590 Binary — Stacked Wakes Observed

**Severity:** HIGH (feature broken in production)
**Discovered by:** jungle-coder during #590 dogfood review
**Date:** 2026-05-01T03:30:00Z
**Affected hosts:** lumi-test, tyyni-test

## Symptom

tyyni-test tmux pane shows `[c2c] check inbox` appearing **twice** in the input box with `2 queued`:
```
Thinking   .  3s · 234 tokens · 63 tok/s
❯ [c2c] check inbox
❯ [c2c] check inbox
↑ to edit · ctrl-s to send immediately
── input · 2 queued ──────────────────────────────────
```

This is exactly the stuck-wake scenario #590 was designed to prevent: the prior wake's text was typed but not submitted, and subsequent wakes stacked on top.

## Root Cause

The `c2c-kimi-notif` subprocess is running a **pre-#590 binary** (before the three-guard idle detection). Evidence:

- `c2c start kimi -n lumi-test` started: 09:43 May 1
- `c2c start kimi -n tyyni-test` started: 10:06 May 1
- `/home/xertrov/.local/bin/c2c` binary mtime: **12:20 May 1** (newer than both starts)
- `exe -> /home/xertrov/.local/bin/c2c (deleted)` — process is running the old inode; new binary on disk has #590 code

The notifier did NOT auto-restart after `just install-all` or `c2c install all` replaced the binary.

## Three-Guard Status (pre-restart)

All three guards from #590 are **not yet live** on these hosts:
- Guard (a) busy-marker: unknown (can't observe pre-change behavior cleanly now)
- Guard (b) wire.jsonl mtime: NOT RUNNING (pre-#590 code)
- Guard (c) pending wake in input box: NOT RUNNING — **this is the visible symptom**

The double `[c2c] check inbox` confirms guard (c) would have fired if the new binary were running.

## Fix

Restart the notifier on both hosts:
```
c2c restart lumi-test
c2c restart tyyni-test
```

Or for a clean restart:
```
c2c stop lumi-test && c2c start kimi -n lumi-test
c2c stop tyyni-test && c2c start kimi -n tyyni-test
```

## Follow-up

- Need a restart hook or inotify on the c2c binary to auto-restart notifier children when binary changes. This is a general operational issue — `just install-all` replaces the binary but long-running notifier processes keep using the old code.
- Filed as potential improvement: notifier auto-restart on binary replacement.

## Status

**Fixable** — needs `c2c restart` on affected instances. Not a code defect in #590.