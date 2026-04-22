# Dogfood Finding: compacting-status End-to-End Works (with Persistence Bug Found)

## Timestamp
2026-04-22T22-04-00Z

## Alias
galaxy-coder

## What Was Tested
Live dogfood test of the compacting-status feature:
1. `c2c set-compact --reason "live-test"` — sets compacting flag
2. `c2c send galaxy-coder "test"` — sends to self while compacting
3. `c2c clear-compact` — clears flag
4. `c2c send galaxy-coder "test"` — verifies no warning after clear

## Result: PASS (with one bug found and fixed)

### Bug Found: `compacting` field not persisted to registry.json

**Symptom**: After `c2c set-compact`, the compacting flag was set in-memory and the send-side warning worked during the live session. However, `registry.json` had no `compacting` field for the registration — meaning the flag would be lost on broker restart.

**Root Cause**: `registration_to_json` (c2c_mcp.ml line ~247) did not serialize the `compacting` field, while `registration_of_json` (line ~327) could deserialize it. The persistence was one-directional.

**Fix**: Added `compacting` serialization to `registration_to_json`, matching the `compacting_of_json` deserialization already in place.

**Files changed**: `ocaml/c2c_mcp.ml` (registration_to_json function)

### End-to-End Chain Verification

After fix, all steps work correctly:

```
$ c2c set-compact --reason "live-test" --json
{"ok": true, "started_at": 1776857069.514053}

$ c2c send galaxy-coder "test with warning?" --json
{
  "queued": true,
  "ts": 1776857074.484558,
  "from_alias": "galaxy-coder",
  "to_alias": "galaxy-coder",
  "compacting_warning": "recipient compacting for 5s (live-test)"
}

$ c2c clear-compact --json
{"ok": true}

$ c2c send galaxy-coder "test after clear" --json
{"queued": true, "ts": 1776857080.34692, "from_alias": "galaxy-coder", "to_alias": "galaxy-coder"}
```

Also verified: `registry.json` now contains `{"started_at": ..., "reason": "live-test"}` under the `compacting` key for the registration.

## Principle Validated

This is exactly why CLAUDE.md says "dogfood before declaring done" — the persistence bug was not visible in unit tests (which test in-memory broker state) and only surfaced under live use. The test would have passed but the feature would have silently failed in production after any broker restart.
