# Bug: Monitor label not cleared on kill when pending events exist

**Filed by**: CEO
**Date**: 2026-04-23
**Severity**: medium
**Status**: CLOSED — OpenCode-native issue, no c2c-side fix possible (informational)

## Symptom

When a persistent `Monitor` is killed via `monitor_kill` and then recreated with the same label, OpenCode responds with "label already exists" even though the previous instance is dead.

Even after `monitor_kill`, if the old instance had accumulated pending events, the label stays "in use" and blocks recreation.

## Root Cause

This is an **OpenCode-native bug** in the `Monitor` tool lifecycle management, not a c2c bug.

OpenCode's internal registry tracks active monitors by label. When `monitor_kill` is called:
1. The monitor **process** is terminated (SIGTERM)
2. The **label** entry in OpenCode's registry is NOT cleared if there are pending events
3. `monitor_fetch` on the dead entry flushes the pending events AND clears the label from the registry
4. Only after `monitor_fetch` can a new monitor with the same label be created

## Workaround

After killing a monitor and before recreating it with the same label, call `monitor_fetch` on the dead entry to clear it:

```
monitor_fetch label="c2c-archive-monitor"
monitor_start ... (same label)
```

## c2c-side Mitigation

None possible — this is in OpenCode's Monitor tool implementation, not c2c code.

## Files Referenced

- `_MONITOR_C2C_OPENCODE.md` — documents the monitor setup; workaround noted above
- OpenCode plugin: `.opencode/plugins/c2c.ts` — uses `Monitor` tool but does not manage monitor lifecycle

## Impact on c2c

Agents that arm `Monitor({persistent: true})` for inbox wake need to be aware of this bug. On restart, if the monitor process was killed uncleanly, the agent must call `monitor_fetch` before re-arming the same label.

The standard recovery snippet (`.c2c/snippets/recovery.md`) may need to be updated to include this workaround.
