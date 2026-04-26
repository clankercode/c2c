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

### 1. ~~`room.leave` never removes alias from `roomMembers`~~ ✅ Fixed (2fd82ea)
`App.tsx` lines 115-125 now delete the alias from the `roomMembers` map on `room.leave`, and clean up the room entry if it becomes empty. Fixed 2026-04-22.

### 2. ~~`MAX_EVENTS` cap does not apply to `events` state~~ ✅ Fixed
`setEvents` calls at lines 88-90 and 515-517 cap the array to `MAX_EVENTS` elements before storing. Both the monitor event path and the send path are covered.

### 3. ~~`pollInbox` timestamps are poll time, not message time~~ ✅ Fixed
Added `ts : float` to the broker `message` type (set to `Unix.gettimeofday()` on enqueue), emitted in `c2c poll-inbox --json` output, consumed in `useHistory.ts` — `m.ts ?? now` so messages show their actual enqueue time. Falls back to poll time for legacy messages read from old inbox files lacking the field.

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

→ ~~No toast/notification system~~ — ✅ fixed. `useToast.ts` singleton with `toast.error/success/warning()`, `ToastContainer` component, 5s cooldown dedup. `useHistory` and `useSend` errors now surface as toasts. ComposeBar retry button unchanged.

---

## UX Gaps

1. **No sent-message local record** — sent messages only appear if the monitor broadcasts them. Direct DM to a dead peer = no record.

2. ~~**60s discovery polling**~~ — ✅ fixed. `refreshBroker()` now polls at 10s interval (`10_000`ms). New peers appear within ~10s of startup.

3. **WelcomeWizard skip puts app in observer mode** — no way to send messages, no prompt to register later.

4. ~~**No markdown/code block rendering**~~ — ✅ fixed. Focused chat bubbles and expanded global messages now render fenced code blocks, inline code, and bold text.

5. **No message delivery confirmation** — "sent ✓" disappears after 1.5s even if the broker rejected the message.

6. **No typing indicators or read receipts** — standard chat features absent (acceptable for v1).

7. **Global feed shows all event types** — drain/sweep/peer.alive interleaved with messages is noisy.

---

## Performance

1. ~~**No virtualization on EventFeed**~~ — ✅ fixed 8056920. `useVirtualizer` in EventFeed.tsx; globalVirtualizer + dynamicVirtualizer.

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
| ~~**High**~~ | ~~Fix `room.leave` to remove alias from `roomMembers`~~ — ✅ fixed 2fd82ea |
| ~~**High**~~ | ~~Add Zod validation at all CLI JSON ingestion points~~ — ✅ fixed (8 safeParse validators covering monitor, history×4, discovery×3, permissions, outbox; committed 04d8d49b)
| ~~**Medium**~~ | ~~Virtualize EventFeed (react-virtual or similar)~~ — ✅ fixed 8056920 |
| ~~**Medium**~~ | ~~Add error toasts for transient CLI failures~~ — ✅ fixed (useToast singleton + ToastContainer) |
| ~~**Medium**~~ | ~~Reduce discovery polling from 60s to ~10s~~ — ✅ fixed |
| ~~**Low**~~ | ~~Implement sent-message local outbox~~ — ✅ fixed (useOutbox hook + pending count in UI) |
| ~~**Low**~~ | ~~Memoize `dedupeAndSort` or move to useMemo~~ — ✅ fixed (dedupeAndSort wrapped in useMemo, filteredVisible keyed on [selectedRoom,selectedPeer,events,focusHistoryEvents,myAlias,filter]) |
| ~~**Low**~~ | ~~Add markdown rendering for messages~~ — ✅ fixed |
| ~~**Medium**~~ | ~~PermissionPanel for pending permission requests~~ — ✅ fixed (PermissionPanel.tsx + usePermissions hook; lyra/stanza slice) |
| **Broker** | pollInbox timestamps — broker `message` type lacks timestamp field |
