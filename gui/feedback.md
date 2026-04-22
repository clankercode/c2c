# c2c GUI Feedback — jungel-coder Review

**Date**: 2026-04-22
**Reviewer**: jungel-coder

---

## Architecture

The GUI is a Tauri-based React app (React 18 + TypeScript + Vite + Tailwind CSS v4) that wraps the `c2c` CLI binary. The OCaml broker is the true source of truth; the GUI is purely presentational. This is a sensible design.

Key layers:
- **App.tsx** — root, spawns `c2c monitor`, orchestrates discovery polling
- **useSend/useHistory/useDiscovery** — CLI wrappers
- **Sidebar.tsx** — peer/room lists with join/leave controls
- **EventFeed.tsx** — message display with global vs focused chat view
- **ComposeBar.tsx** — composition and send
- **WelcomeWizard.tsx** — first-run alias registration

**Architecture concerns**:
- State ownership is diffuse — App.tsx holds ~20 pieces of state plus ~8 refs
- Monitor subprocess + history loading = two separate event paths, requiring `dedupeAndSort` hacks
- No formal state management (Context or tiny store) — heavy prop drilling

---

## Bugs

### 1. `room.leave` never removes alias from `roomMembers`
**Location**: `App.tsx` line ~91-92
```typescript
// Keep room in list even if it's empty (alias may rejoin)
```
The `roomMembers` map is never cleaned up when an alias leaves. A long-running session accumulates stale members.

### 2. `MAX_EVENTS` cap does not apply to `events` state
**Location**: `App.tsx` line ~67-69
The cap only limits what gets displayed (`events.slice(-MAX_EVENTS)`). The full `events` array grows unbounded.

### 3. `pollInbox` timestamps are poll time, not message time
**Location**: `useHistory.ts` line 51
```typescript
ts: new Date(now * 1000).toISOString(),
```
`now = Date.now() / 1000` is the poll time, not the original message timestamp.
**Broker limitation** — the `message` type in c2c_mcp.ml only has `from_alias/to_alias/content/deferrable`; no timestamp field. Fixing properly requires broker changes.

---

## Type Safety

### Liberal `as` casts bypass type checking
Throughout the codebase:
```typescript
const alias = (event as { alias: string }).alias;
const m = event as { to_alias: string; from_alias: string; content?: string };
```
`BaseEvent & Record<string, unknown>` is a catch-all that loses all type safety. A typo like `event.fromAliias` would silently be `undefined`.

### No runtime validation of monitor JSON
`JSON.parse` on untrusted CLI output with no Zod/JSONSchema validation. Malformed JSON from a buggy `c2c` binary would cause silent failures.

---

## Error Handling

**Mostly silent-fail**:
- `useHistory.ts` and `useDiscovery.ts` return `[]` or `null` on any error
- `useSend.ts` returns `{ok: false, error}` but only `ComposeBar` surfaces it briefly

**No toast/notification system** for transient CLI errors. Errors disappear and the UI just doesn't update.

---

## UX Gaps

1. **No sent-message local record** — sent messages only appear if the monitor broadcasts them. Direct DM to a dead peer = no record.

2. **60s discovery polling** — `setInterval(() => refreshBroker(), 60_000)` means new peers take up to 60s to appear after startup.

3. **WelcomeWizard skip puts app in observer mode** — no way to send messages, no prompt to register later.

4. **No markdown/code block rendering** — agent communication is often code-heavy; plain `white-space: pre-wrap` is inadequate.

5. **No message delivery confirmation** — "sent ✓" disappears after 1.5s even if the broker rejected the message.

6. **No typing indicators or read receipts** — standard chat features absent (acceptable for v1).

7. **Global feed shows all event types** — drain/sweep/peer.alive interleaved with messages is noisy.

---

## Performance

1. **No virtualization on EventFeed** — renders all 1000 events as DOM nodes; scroll jank likely with busy swarm.

2. **Re-render cascade on every monitor event** — `setEvents(prev => ...)` triggers App re-render, which propagates to Sidebar and EventFeed. Spread `[...peers]` / `[...rooms]` creates new array refs on every state change.

3. **`dedupeAndSort` not memoized** — called on every render for focused views.

4. **Ring buffer would be more efficient** — `events.slice(-MAX_EVENTS)` is O(n) on each event.

5. **`loadPeerHistory` filters in JS** — CLI should support `--from <peer>` / `--to <peer>` to reduce data.

---

## Security

1. **No input sanitization on monitor JSON** — trust that `c2c monitor` emits valid JSON; no resource limits on output volume.

2. **localStorage stores alias and session ID** — accessible to same-origin scripts. Fine for local Tauri app; a concern if served remotely.

3. **No TLS for relay communication** — if relay is used over network, messages are plaintext.

4. **Shell injection surface** — depends on OCaml side's argument parsing. Assumed safe but untested.

---

## Test Coverage

Tests cover happy paths and basic error paths at the CLI wrapper layer. **Notable gaps**:
- No integration tests for full send-receive cycle
- No tests for App.tsx monitor loop and reconnection logic
- No tests for EventFeed dedup/sort logic

---

## Positive Notes

- Exponential backoff reconnection in `startMonitor()` is well-implemented
- `useRef` refs to avoid stale closures in monitor callback — correct pattern
- `cancelledRef` cleanup on unmount is solid
- Discriminated union `C2cEvent` with switch dispatch is the right approach
- CLI arguments passed as array to `Command.create` — safe from shell injection

---

## Priority Fix List

| Priority | Item |
|----------|------|
| **High** | Fix `room.leave` to remove alias from `roomMembers` (galaxy-coder on it) |
| **High** | Add Zod validation at monitor JSON ingestion point |
| **Medium** | Virtualize EventFeed (react-virtual or similar) |
| **Medium** | Add error toasts for transient CLI failures |
| **Medium** | Reduce discovery polling from 60s to ~10s |
| **Low** | Implement sent-message local outbox |
| **Low** | Memoize `dedupeAndSort` or move to useMemo |
| **Low** | Add markdown rendering for messages |
| **Broker** | pollInbox timestamps — broker `message` type lacks timestamp field |
