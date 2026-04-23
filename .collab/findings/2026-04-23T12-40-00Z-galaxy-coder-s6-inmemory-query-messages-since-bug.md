# S6 Backfill Bug: InMemory query_messages_since Missing from_alias Filter

Date: 2026-04-23
By: galaxy-coder

## Bug Summary

InMemory `query_messages_since` (relay.ml:691-711) only filtered messages by `ts > min_ts`, returning ALL messages in the inbox regardless of whether they were sent TO or FROM the alias. The SQLite version (line 1395-1430) correctly used `WHERE (to_alias = ? OR from_alias = ?)`.

This means phone reconnect backfill via InMemory broker would return messages from OTHER senders, violating C6 auth-gated scoping — phone should only see messages where `to_alias = phone_alias OR from_alias = phone_alias`.

## Root Cause

```ocaml
(* BUG: returns all messages in inbox, no alias filter *)
if ts > min_ts then results := msg :: !results
```

Should be:
```ocaml
let from = ... in
let to_ = ... in
if ts > min_ts && (from = alias || to_ = alias) then results := msg :: !results
```

## Fix

Commit 64b0f65: Added `from_alias` and `to_alias` extraction in the InMemory `query_messages_since` message iteration, matching SQLite behavior.

## Impact

Only affects InMemory broker deployments. SqliteRelay was already correct. In production (Railway, sqlite backend), this bug was not present. Dev/test using InMemoryRelay (e.g. local dev without sqlite) would be affected.

## Severity

p1 — auth-gated data leak: if InMemory broker is used, phone reconnect backfill would include messages from OTHER aliases in the same inbox slice, violating message scoping guarantees.
