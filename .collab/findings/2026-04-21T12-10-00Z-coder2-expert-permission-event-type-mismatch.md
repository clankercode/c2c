---
date: 2026-04-21T12:10:00Z
author: coder2-expert
severity: MEDIUM — breaks async supervisor DM for config-declared bash:ask
status: FIXED (6828ce6)
---

# Plugin permission event type mismatch: permission.updated vs permission.asked

## Symptom

Config-declared `bash:ask` in `opencode.json` showed TUI dialog but plugin's
`event` handler and `permission.ask` hook did NOT fire. No DM sent to supervisor,
no log entry in `.opencode/c2c-debug.log`.

Runtime-ask path (tool-level ask at runtime) worked correctly at 01:12 UTC.

## Root Cause

Two different event type strings are in play:

| Source | Event type string | When emitted |
|--------|------------------|--------------|
| OpenCode internal bus | `"permission.asked"` | Tool-level runtime ask |
| OpenCode SDK Event subscription | `"permission.updated"` | All permission events (per SDK types.gen.d.ts) |

The SDK type `EventPermissionUpdated` has `type: "permission.updated"`. This is
what the plugin's `event:` callback receives via the external event subscription.

planner1's earlier fix (9ba7724 / 733a026) changed the check from
`"permission.updated"` → `"permission.asked"` based on opencode's internal
bus log. This worked for the runtime-ask path (which fires the internal bus
event AND the external SDK event), but NOT for config-declared asks (which
only fire the external SDK event `"permission.updated"`).

## Evidence

- SDK types: `@opencode-ai/sdk/dist/gen/types.gen.d.ts:384` defines
  `EventPermissionUpdated { type: "permission.updated"; properties: Permission }`
- Debug log: zero permission entries during config-declared bash:ask TUI dialog
- Debug log: successful DM at 01:12 UTC was a runtime-ask path

## Fix (6828ce6)

Plugin event handler now checks BOTH types:
```typescript
if (event.type === "permission.updated" || event.type === "permission.asked") {
```

Also added `await log(...)` at entry of `permission.ask` hook so it's visible
when the hook fires (vs the event path) for further debugging.

## Outstanding question

Does `permission.ask` hook fire for config-declared bash:ask? The event path
(v1 notification) will now work. But the v2 async hook (which can block the
dialog and await a structured reply) may still not fire for config-declared asks
if OpenCode routes config-declared permissions differently. Needs validation
after oc-coder1 restart.

## Fix for relay_list_cmd admin route

Separate fix in same session: `relay list --dead` uses `/list?include_dead=1`
which is an ADMIN route (Bearer only). Only `/list` (no include_dead) is a
peer route needing Ed25519. Fixed in 0734082.
