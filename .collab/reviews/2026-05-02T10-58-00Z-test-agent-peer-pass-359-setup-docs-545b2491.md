# Peer-PASS: #359 — stale Kimi Wire bridge docs fix (545b2491 + 8b7f3b48)

**reviewer**: test-agent
**commits**:
- `545b2491` — fix(docs): replace stale Kimi "Wire bridge" refs with notification-store — 3 files
- `8b7f3b48` — fix(docs): known-issues.md Kimi "Wire bridge" → notification-store — 1 file
**author**: stanza-coder
**branch**: slice/359-setup-docs
**scope**: 4 docs files, +6/-6

## Verdict: PASS

## Changes

All four files update stale references to "Wire bridge" with the correct notification-store terminology:

1. **docs/clients/feature-matrix.md**: "Wire bridge (stdio)" → "Notification-store (`C2c_kimi_notifier`)" in Auto-delivery row; "Wire bridge + TUI poll" → "`C2c_kimi_notifier` writes notification files + tmux idle-wake" in deliver daemon row ✅

2. **docs/get-started.md**: "Kimi (Wire bridge)" → "Kimi (notification-store)" in four-client parity line ✅

3. **docs/index.md**: "Kimi (Wire bridge)" → "Kimi (notification-store)" in four-client parity line ✅

4. **docs/known-issues.md**: "Kimi uses Wire bridge" → "Kimi uses notification-store delivery" in PTY deprecation section ✅

All replacements are accurate per kimi-wire-bridge-cleanup (S4, 3c0df1cc). No code changes — build N/A.
