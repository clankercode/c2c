# #494 `per_*` permission-DM verdict flow — investigation

- **Author:** birch-coder
- **Date:** 2026-04-30
- **Status:** FINDING — investigation complete
- **Cross-references:**
  - `#461` diagnostic sweep (root cause of permission DM timeouts)
  - `#493` permission-approval-disciplines runbook (token format: `ka_*` vs `per_*` distinction)
  - `#495` spool-aware peek fix (deliverInbox race condition)
  - `.collab/findings/2026-04-30T20-50-birch-coder-461-diagnostic-sweep.md`

---

## Q1: Does it use `c2c await-reply` or its own polling loop?

**OpenCode plugin**: **own polling loop** — `waitForPermissionReply()` creates a `setTimeout` that fires once after `permissionTimeoutMs`. At timeout, it calls `peekInboxForPermission(permId)` which checks broker inbox, then spool.

**Kimi hook**: uses `c2c await-reply` CLI (the OCaml-based polling loop), which reads verdict files written by `c2c approval-reply`. This is the `ka_*` token path — different from the OpenCode permission flow.

The two flows are **completely separate**:
- OpenCode `permission.*` events → `pendingPermissions` Map → supervisor DMs with `permission:<id>:<decision>` → `postSessionIdPermissionsPermissionId` HTTP resolve
- Kimi PreToolUse hook → `ka_*` token → `c2c approval-pending-write` → `c2c approval-reply` → verdict file → `c2c await-reply`

---

## Q2: Where is the tick interval defined? Does it consult the spool?

**OpenCode plugin tick interval**: Not a recurring interval — a **single `setTimeout`** fires after `permissionTimeoutMs` (default: from `permission_timeout_ms` in sidecar config, typically 60-120s). After that timeout fires, it does ONE `peekInboxForPermission` call and resolves (approve-once, approve-always, or reject).

**Spool consulted**: Yes. `peekInboxForPermission` (lines 1307-1337 in `data/opencode-plugin/c2c.ts`):
1. Check broker inbox via `peek-inbox --json`
2. If nothing found, check spool via `readSpool()`
3. If still nothing, resolve as timeout

The spool check was the `#495` fix — without it, a reply that arrived just before the timeout but after the inbox was drained by `deliverMessages` would be missed. The spool path is now covered.

**No recurring poll loop**: Unlike `c2c await-reply` which polls on a 1s interval, the OpenCode plugin does a **single shot** after the permission timeout. If no reply arrives within the window, it auto-rejects.

---

## Q3: Is the verdict format consistent with current peer-PASS DM shape?

**Format used by OpenCode plugin** (supervisor receives this as a DM):
```
PERMISSION REQUEST from <instance>:
  action: <summary>
  id: <permId>
  session: <sessionId>
Reply within <timeout>s:
  c2c send <alias> "permission:<permId>:approve-once"
  c2c send <alias> "permission:<permId>:approve-always"
  c2c send <alias> "permission:<permId>:reject"
(timeout → auto-reject; late replies will be NACK'd)
```

**Decision regex** (`extractPermissionReply` in `c2c.ts` line 166):
```
/\bpermission:([a-zA-Z0-9_-]+):(approve-once|approve-always|reject)\b/
```

**Format vs peer-PASS DM shape**: The peer-PASS verdict format is `ka_<token> allow` / `ka_<token> deny`. The permission flow uses a **different format** (`permission:<id>:<decision>`). These are **two completely separate mechanisms**:
- `ka_*`: PreToolUse approval token for the kimi hook path
- `permission:<id>:<...>`: OpenCode's internal permission dialog, not peer-PASS

The `#392` visual indicators (🔴 FAIL:, ⚠️ URGENT:) are **NOT used** in the permission DM format — this is a deliberate design choice (permission requests are informational, not PASS/FAIL verdicts).

---

## Gaps identified

### G1 (MEDIUM): `pendingPermissions` Map has unbounded growth

**Where**: `data/opencode-plugin/c2c.ts` lines 379-382

```ts
const pendingPermissions = new Map<string, {
  resolve: (reply: string) => void;
  supervisors: string[];
}>();
```

**Problem**: Entries are added via `pendingPermissions.set(permId, ...)` when `permission.asked` fires and removed when a reply arrives or the timeout fires. However, entries are added to `seenPermissionIds` (a dedup list) and the `seenPermissionIds.includes(permId)` guard prevents duplicate processing. BUT — if an agent emits `permission.asked` events for many unique `permId`s without the map being cleaned up between them, `pendingPermissions` grows indefinitely within a session.

**Worse**: The `seenPermissionIds` dedup window has a max of 20 entries (line 1851: `if (seenPermissionIds.length > 20) seenPermissionIds.shift()`). After 20 unique permission IDs, earlier ones are evicted from the dedup window. If those earlier IDs' timeouts haven't fired yet, they remain in `pendingPermissions` with no way to resolve them — the Map is orphaned.

**Fix**: Add a capacity cap on `pendingPermissions` (e.g., max 20 concurrent pending), and/or add a periodic cleanup pass that evicts timed-out entries that somehow survived (defensive belt-and-braces). A simpler fix: when `seenPermissionIds` evicts an entry, check if it's still in `pendingPermissions` and clean up.

**Severity**: Medium — affects agents that generate many permission requests within a single session. Low-frequency in normal use.

### G2 (LOW): `timedOutPermissions` is memory-only, not persisted

**Where**: `data/opencode-plugin/c2c.ts` lines 390-396

The `timedOutPermissions` Map stores timed-out permission IDs in memory with a 30-minute TTL. If the OpenCode process restarts within that 30-minute window, the information is lost. The late-reply NACK (`permission <permId> timed out...`) won't be sent, and a supervisor's late reply would be accepted (or silently dropped depending on `seenPermissionIds` state).

**Fix**: Persist `timedOutPermissions` to a file (similar to the OCaml `pending_permissions.json`) so it survives restarts. Or accept the limitation as v1 — restart window is small.

### G3 (DOCS): `ka_*` vs `permission:<id>:` token format distinction not documented

The `#493` runbook correctly documents the `ka_*` token format and the kimi PreToolUse approval path. The OpenCode `permission:<permId>:<decision>` format is not documented anywhere in the runbooks. An operator trying to manually respond to an OpenCode permission request would need to reverse-engineer the format from the DM body.

**Fix**: Add a section to the permission-approval-disciplines runbook covering the OpenCode permission DM format, the `permission:<id>:approve-once|approve-always|reject` pattern, and the `c2c send <alias> "permission:<id>:approve-once"` response format.

---

## Answers to coordinator's questions

1. **Does it use `c2c await-reply` (MCP path) or its own polling loop?**
   → OpenCode: own polling loop (`waitForPermissionReply` → `setTimeout` + `peekInboxForPermission`)
   → Kimi hook: `c2c await-reply` via verdict file path (the `ka_*` format)

2. **Where is tick interval defined, and does it consult the spool?**
   → OpenCode: single-shot `setTimeout` after `permissionTimeoutMs`; spool consulted at timeout via `peekInboxForPermission` (#495 fix covers this)
   → Tick interval is NOT a recurring interval — one-shot at permission timeout

3. **Is verdict format consistent with current peer-PASS DM shape?**
   → NO — the permission flow uses `permission:<permId>:approve-once|approve-always|reject`, which is a different format from the `ka_<token> allow/deny` peer-PASS verdict shape
   → These are two separate mechanisms (OpenCode internal permission dialog vs kimi PreToolUse approval)
   → The `#392` visual indicators (🔴 FAIL:, ⚠️ URGENT:) are NOT used in permission DMs

---

## Relationship to #493

The `#493` permission-approval-disciplines runbook correctly identifies the `ka_*` token format for the kimi hook path. The OpenCode `permission:<permId>:<decision>` format is a **sibling mechanism** — both ultimately resolve to allow/deny for a tool call, but they use different wire formats and resolution paths.

---

## Slice recommendations

| Gap | Severity | Slice | Owner |
|-----|----------|--------|--------|
| G1: `pendingPermissions` unbounded growth | MEDIUM | New slice to cap + GC the Map | TBD |
| G2: `timedOutPermissions` not persisted | LOW | Accept as v1 limitation, or file a follow-up | TBD |
| G3: permission DM format not documented | LOW | Add to `#493` runbook | birch or fern |

---

*Cross-links:*
- `.collab/findings/2026-04-30T20-50-birch-coder-461-diagnostic-sweep.md`
- `.collab/runbooks/permission-approval-disciplines.md` (#493)
- `data/opencode-plugin/c2c.ts` lines 379-396, 1402-1417, 1833-1934
