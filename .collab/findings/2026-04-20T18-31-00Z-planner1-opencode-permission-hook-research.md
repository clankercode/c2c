---
author: planner1
ts: 2026-04-20T18:31:00Z
severity: medium
status: research-complete — async hook confirmed, v1 task created (#1), v2 design below
---

# OpenCode Permission Hook Research: Async Supervisor Approval via Plugin

## Summary

OpenCode **does** expose a `Hooks.permission.ask` plugin hook that fires before the
permission dialog blocks the TUI. This makes a c2c-based async approval flow
**feasible at HIGH confidence** without an upstream patch.

---

## 1. What APIs Exist

### Plugin Hook: `Hooks.permission.ask`

- Called synchronously (or async with Promise) before the dialog appears
- Input: `Permission` object — type, pattern, title, metadata
- Output: `{ status: "ask" | "deny" | "allow" }`
  - `"ask"` → show dialog as normal (current behavior)
  - `"allow"` → auto-approve, TUI never blocks
  - `"deny"` → reject without dialog

**This is the key API.** If we return a Promise and resolve it after receiving a
c2c DM reply, the TUI waits on our plugin rather than showing a blocking dialog.

### Permission Events

- `permission.updated` — fires when a permission prompt is created
- `permission.asked` — v2 SDK variant
- `permission.replied` — fires when answered (both v1 and v2)

### Programmatic Reply APIs

- v1: `client.postSessionIdPermissionsPermissionId(sessionID, permID, { response: "once"|"always"|"reject" })`
- v2: `client.permission.reply(requestID, { reply: "once"|"always"|"reject", message?: string })`

### TUI State (v2 only)

- `ctx.client.tui.state.session.permission(sessionID)` → `PermissionRequest[]`
- Can poll for pending permissions without event subscription

---

## 2. Complete Event Types (33 total)

`server.instance.disposed`, `installation.updated`, `installation.update-available`,
`lsp.client.diagnostics`, `lsp.updated`, `message.updated`, `message.removed`,
`message.part.updated`, `message.part.removed`, **`permission.updated`**,
**`permission.replied`**, `session.status`, `session.idle`, `session.compacted`,
`file.edited`, `todo.updated`, `command.executed`, `session.created`,
`session.updated`, `session.deleted`, `session.diff`, `session.error`,
`file.watcher.updated`, `vcs.branch.updated`, `tui.prompt.append`,
`tui.command.execute`, `tui.toast.show`, `pty.created`, `pty.updated`,
`pty.exited`, `pty.deleted`, `server.connected`

---

## 3. Full ctx.client API Surface (19 namespaces)

`session`, `tui`, `app`, `control`, `config`, `auth`, `provider`, `tool`,
`instance`, `path`, `vcs`, `project`, `pty`, `command`, `find`, `file`,
`mcp`, `lsp`, `formatter`, `event`, `permission` (v2)

**Permission-specific**:
- v1: `client.postSessionIdPermissionsPermissionId(...)`
- v2: `client.permission.reply(...)` / `client.permission.respond(...)`

---

## 4. Proposed Design

### Approach A: Supervisor DM + async reply (notification + approval)

```
permission.ask hook fires
  → DM coordinator1: "opencode-test requests permission: <type> <pattern>"
  → Start 60s timeout timer
  → Await reply: { cmd: "approve-once|approve-always|reject" }
  → If reply arrives in time: return { status: reply }
  → If timeout: return { status: "ask" }  (fallback to dialog)
  → Also toast in TUI: "Waiting for coordinator1 approval..."
```

c2c delivery for the reply: coordinator1 sends structured DM like:
```
<c2c-permission-reply action="approve-once" />
```
Plugin's `deliverMessages` path already handles arbitrary text; we parse it before
passing to `promptAsync`.

### Approach B: Notification-only (no auto-approve)

```
permission.ask hook fires
  → DM coordinator1: "BLOCKED: opencode-test waiting on permission dialog"
  → return { status: "ask" }  (show dialog, session still blocks)
  → At least the swarm is notified and can take remedial action
```

Simpler but doesn't fix the blocking — only surfaces it. Useful as v1 before
full async approval is wired.

---

## 5. Feasibility Assessment

| Approach | Feasibility | Notes |
|----------|-------------|-------|
| Plugin hook (`permission.ask`) | **HIGH** | Direct hook exists; async Promise should work |
| Notification-only (approach B) | **HIGH** | Subset of above; very low impl risk |
| Event-driven monitoring | **MEDIUM** | `permission.updated` fires but needs separate reply path |
| TUI control queue interception | **LOW** | Generic, not purpose-built for permissions |
| Upstream patch | **MEDIUM** | Not needed given hook exists; useful if hook is sync-only |

---

## 6. Open Questions

1. **Does `permission.ask` accept async (Promise-returning) handlers?** If the hook
   must return synchronously, approach A needs to be restructured (deliver+notify
   async, always return `"ask"` to avoid the dialog until a separate mechanism
   pre-approves on next attempt).

2. **Which SDK version is installed?** v1 vs v2 determines which reply API to use.
   Check: `ls node_modules/@opencode-ai/sdk/` for version.

3. **Structured c2c reply format**: needs a simple, unambiguous format so coordinator1
   can reply with `approve-once`, `approve-always`, or `reject` without cluttering
   the transcript.

---

## 7. Next Step

Low-risk v1: add notification-only to the existing `c2c.ts` plugin:
- On `permission.updated` event, DM coordinator1 with permission details
- No change to `permission.ask` hook yet
- Zero risk: existing delivery is unchanged

Higher-value v2: wire `permission.ask` async → DM supervisor → await reply.
Needs validation of async hook support first (question #1 above).

**Recommended**: implement notification-only first (quick, safe), then add async
approval as a follow-on slice. coordinator1 gets paged immediately when any
opencode session hits a permission dialog.

---

## 8. Async Hook Confirmed + v2 Design

### Verified: permission.ask IS async

From `.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts`:

```typescript
"permission.ask"?: (input: Permission, output: {
    status: "ask" | "deny" | "allow";
}) => Promise<void>;
```

The hook returns `Promise<void>` and mutates `output.status`. We can `await` inside
it — including waiting for a c2c DM reply — before returning.

### Permission type fields

```typescript
Permission = {
  id: string;          // unique, use for deduplication
  type: string;        // e.g. "tool", "network", "file"
  pattern?: string | string[];   // the resource path/pattern being requested
  sessionID: string;
  messageID: string;
  callID?: string;
  title: string;       // human-readable description e.g. "Access ~/.local/bin/"
  metadata: Record<string, unknown>;
  time: { created: number };
}
```

### v2 Full Design: Async Approval via c2c DM

```typescript
"permission.ask": async (input: Permission, output) => {
  // 1. Notify supervisor
  const supervisorAlias = process.env.C2C_PERMISSION_SUPERVISOR || "coordinator1";
  const msg = [
    `PERMISSION REQUEST from ${sessionId}:`,
    `  title: ${input.title}`,
    `  type: ${input.type}`,
    `  pattern: ${JSON.stringify(input.pattern ?? "N/A")}`,
    `  id: ${input.id}`,
    `Reply within 60s: c2c send ${sessionId} "permission:${input.id}:approve-once"`,
    `  or: "permission:${input.id}:approve-always"`,
    `  or: "permission:${input.id}:reject"`,
  ].join("\n");
  await runC2c(["send", supervisorAlias, msg]);

  // 2. Await structured reply with 60s timeout
  const reply = await waitForPermissionReply(input.id, 60_000);
  
  // 3. Apply decision
  if (reply === "approve-once" || reply === "approve-always") {
    output.status = "allow";
  } else if (reply === "reject") {
    output.status = "deny";
  } else {
    // timeout — fall back to dialog
    output.status = "ask";
  }
}
```

`waitForPermissionReply` would poll the c2c inbox every 2s looking for a message
matching `permission:<id>:<decision>`. The existing `drainInbox()` helper handles
the poll.

### Structured Reply Format

Supervisor sends:
```
c2c send opencode-test "permission:<permission-id>:approve-once"
```
or just a short alias like `approve`, `always`, `reject` if the plugin tracks
the pending permission ID in a Map.

### Implementation Steps for v2

1. Add a `pendingPermissions: Map<string, (reply: string) => void>` to plugin scope
2. In `permission.ask`: insert entry, start 60s timer, await promise
3. In `event` hook on inbound DM: check if message matches `permission:<id>:*`,
   resolve the corresponding promise
4. Clean up map entry on resolution or timeout

**Complexity**: ~50 lines. Depends on v1 (notification DM path) being tested first.

**Task**: create follow-on task once v1 is shipped and validated.

### v2 Open Questions (coordinator1 follow-up)

**(a) Timeout default**

**Recommendation: 120s**, not 60s. Rationale: swarm agents run on 4m keepalive loops
with potential cache-miss overhead. A DM to coordinator1 may sit for up to ~4m before
being seen; 60s would reliably timeout before the supervisor even polls. 120s gives one
full poll cycle. Make it configurable via `C2C_PERMISSION_TIMEOUT_MS` so operators can
tune for their loop cadence. If swarm moves to event-driven Monitor wakes, 30s would
suffice — but 120s is the safe default today.

**(b) Who can approve**

**Recommendation: single supervisor alias** (default `coordinator1`, configured via
`C2C_PERMISSION_SUPERVISOR`). Rationale: ACL complexity is premature — the failure
mode we're solving is "no one knows the session is blocked", not "many people want to
approve". A single trusted supervisor is enough for v2. Post-v2, if multi-approver is
needed, the reply format `permission:<id>:<decision>` is already structured and the
plugin just checks if the sender is in a configured allowlist:
`C2C_PERMISSION_APPROVERS=coordinator1,planner1`.

**(c) Timeout behavior**

**Recommendation: fall through to sync dialog** (`output.status = "ask"`), NOT
auto-reject. Rationale: auto-reject is a footgun — a slow supervisor causes the
session to silently deny legitimate ops, breaking the agent's task with no obvious
cause. The sync dialog is annoying (requires human) but is the safe fallback: at
minimum the session survives. Auto-reject should only be used when explicitly
configured (`C2C_PERMISSION_TIMEOUT_ACTION=reject`) for headless/unattended contexts.

Also: on timeout, send a follow-up DM to supervisor:
`"TIMEOUT: permission ${id} fell through to dialog (no reply within ${timeout}s)"`.
This preserves observability even in the fallback path.

---

## Related

- `.collab/findings/2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md`
  (symptom report that triggered this research)
