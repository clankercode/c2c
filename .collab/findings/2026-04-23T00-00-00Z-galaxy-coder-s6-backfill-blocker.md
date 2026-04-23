# S6 Backfill Blocker: alias<->binding_id Mapping Missing

Date: 2026-04-23
By: galaxy-coder

## Blocker Summary

Tasks 4 (gap detection + broker backfill) and 5 (C6 authorization filtering) were blocked by the missing alias<->binding_id mapping. **RESOLVED via Option A.**

## Resolution

Implemented Option A:
- Added `alias_of_identity_pk : t -> identity_pk:string -> string option` to RELAY interface
- Added `query_messages_since : t -> alias:string -> since_ts:float -> Yojson.Safe.t list` to RELAY interface
- Both implemented in SqliteRelay and InMemoryRelay
- Wired into observer WebSocket reconnect handler for gap-based backfill

## Commits

- 34510d0: Add alias_of_identity_pk to RELAY interface
- 8e0df33: Add query_messages_since and alias_of_identity_pk for backfill
- 1c194f9: Wire gap-based backfill into observer WebSocket reconnect

## Limitation (non-blocker, Phase-A scope)

`query_messages_since` only queries `inboxes` (1:1 DMs), not `room_history`.
Room message backfill won't work for gap detection. Acceptable for Phase-A
scope as specified. Phase-B would need room_history query extension.

## Current S6 Implementation Status

| Task | Status | Notes |
|------|--------|-------|
| Task 1: ShortQueue module | ✅ DONE | Committed 8ac73bb |
| Task 2: ShortQueue + observer session | ✅ DONE | Committed 961d273 |
| Task 3: Reconnect replay + gap detection | ✅ DONE | Committed ff90a74 |
| Task 4: Gap detection + backfill | ✅ DONE | Committed 1c194f9 |
| Task 5: C6 authorization filtering | ✅ DONE | Backfill uses alias scope |
| Task 6: Broker-offline handling | ✅ N/A | Relay IS the broker; inbox queue handles offline |
| Task 7: Tests + bug fix | ✅ DONE | Committed 36f1b81 |
| Task 8: Coordinator review | ⏳ PENDING | Awaiting coordinator dispatch |