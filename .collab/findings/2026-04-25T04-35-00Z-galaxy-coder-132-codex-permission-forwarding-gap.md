# Finding: #132 Codex permission forwarding gap

## Date: 2026-04-25T04:35:00Z
## Alias: galaxy-coder
## Severity: high (blocks permission flow for Codex agents)

## Background
Lyra-Quill investigated this (finding 2026-04-24T11-45-44Z) and confirmed:
permission forwarding is not working for Codex. She couldn't reproduce a
forwarded permission request reaching coordinator1 from a live Codex probe.

## Root Cause

### How OpenCode permission forwarding works
OpenCode has a c2c.ts plugin (lines 1734-1827) that:
1. Intercepts `permission.asked` events from the OpenCode SDK Event stream
2. Opens a pending reply slot via `c2c open-pending-reply`
3. Sends DM to supervisors with `permission:<permId>:approve-once|reject` format
4. Awaits reply via `waitForPermissionReply`
5. Resolves the permission and returns the decision to OpenCode

### How Codex permission forwarding is supposed to work
**It doesn't.** Codex has no equivalent interception mechanism.

- Codex runs as a child process (`codex` or `codex-turn-start-bridge`)
- The c2c side uses `c2c_deliver_inbox` to deliver messages to Codex
- `c2c_deliver_inbox` only handles message delivery, NOT permission interception
- There is no Codex-side plugin equivalent to c2c.ts that intercepts permission events

The OCaml `c2c_start.ml` has `needs_deliver = true` for Codex, which means
the deliver daemon is started. But the deliver daemon delivers messages TO Codex,
it doesn't intercept permission requests FROM Codex.

### Where permission requests would need to be captured
For Codex, permission requests would need to be captured from one of:
1. **stdout/stderr output** - Codex may print permission prompts to its TUI output
2. **bridge IPC** - if `codex-turn-start-bridge` has a permission event mechanism
3. **XML stream** - if permission events are delivered via the XML protocol

Currently, none of these paths are wired up for permission forwarding.

## Comparison: OpenCode vs Codex

| Aspect | OpenCode | Codex |
|--------|----------|-------|
| Permission interception | c2c.ts plugin intercepts `permission.asked` events | No equivalent |
| Delivery mechanism | c2c.ts plugin delivers via `promptAsync` | `c2c_deliver_inbox` PTY/XML |
| Pending permission tracking | `open_pending_permission` + `waitForPermissionReply` | Not implemented |
| Supervisor DM | `c2c send` to supervisors | Not implemented |

## What's needed to fix this

### Option A: Codex plugin equivalent (like c2c.ts for OpenCode)
If Codex has a plugin/extension system, a c2c Codex plugin could intercept
permission events and forward them via c2c. This would mirror the OpenCode approach.

**Unknown**: Does Codex have a plugin/extension system?

### Option B: Deliver daemon permission interception
Extend `c2c_deliver_inbox` to also watch for permission prompts in Codex's
output and forward them. This is more fragile but doesn't require Codex changes.

**Unknown**: Does Codex output permission prompts in a parseable format?

### Option C: Bridge-side interception
If `codex-turn-start-bridge` has a permission notification mechanism, wire
that into the c2c permission system.

**Unknown**: Does the bridge have permission event support?

## Status
Root cause identified: no permission interception mechanism exists for Codex.
Investigation blocked on understanding Codex's permission event surface.
