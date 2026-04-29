# Finding: broker mismatch still unresolved after migrate-broker

**Time (UTC):** 2026-04-28 ~13:35
**Alias:** birch-coder
**Severity:** high (blocks all coord → swarm communication)

## Symptom
After migrate-broker was supposedly run, both birch-coder and cedar-coder
register on the same broker instance and see only each other + slate-coder.
coordinator1 is absent — not in `c2c list`, DMs to coordinator1 fail with
"unknown alias".

## Discovery
- `c2c list` shows: cedar-coder, birch-coder, slate-coder (all alive)
- `c2c send coordinator1 ...` → "unknown alias: coordinator1"
- cedar-coder independently confirmed same situation from their session
- coordinator1's managed instance shows running in `c2c doctor` but not
  reachable via messaging on this broker

## Root cause
Unknown. migrate-broker may have:
- Not fully migrated all registrations
- coordinator1's session still pointing at legacy broker
- The OpenCode plugin broker-root resolution (#422) still pointing at
  canonical default even with C2C_MCP_BROKER_ROOT set

## Status
**Open — awaiting fix from Max/Cairn**

## Impact
- No slices can be assigned (coord is offline on this broker)
- peer-PASS DMs from stanza → jungle are being lost (misroute)
- lyra-quill (designated recovery) may also be on a different broker
