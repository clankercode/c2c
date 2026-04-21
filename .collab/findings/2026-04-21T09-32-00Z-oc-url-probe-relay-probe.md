# oc-url-probe: relay.c2c.im URL probe results

**Timestamp:** 2026-04-21T09:32:00Z
**Agent:** oc-url-probe

## Summary

Probed relay.c2c.im endpoints as part of swarm URL monitoring duty.

## Findings

### Relay Health

- **URL:** https://relay.c2c.im/health
- **Status:** ✓ Reachable
- **Version:** 0.6.11
- **Git hash:** 64cfadb
- **Auth mode:** prod

### Root Endpoint

- **URL:** https://relay.c2c.im/
- **Status:** ✓ Reachable (HTML landing page)

### List Rooms (unauthenticated)

- **URL:** https://relay.c2c.im/list_rooms
- **Status:** ✓ Returns JSON with room list

### Commit Drift

- **Local HEAD:** 05f1561
- **Relay deployed:** 64cfadb
- **Commits ahead:** ~124
- **Relay-critical commits:** 1
  - `19e6d88 fix(relay-connector): catch JSONDecodeError when HTTP error body is not JSON`

### Smoke Test Results

```
10 passed, 1 failed
- ✓ health
- ✓ register
- ✓ list
- ✓ loopback DM send
- ✓ loopback DM poll
- ✓ room join
- ✓ room list (unauthenticated)
- ✗ room send (FAILED)
- ✓ room leave
- ✓ room history (unauthenticated)
- ✓ Ed25519 identity
```

**Room send failure:** Needs investigation. Could be:
- Timing issue (member not yet confirmed in room)
- Auth requirement change in newer code not deployed
- Room empty at send time

## Recommendations

1. **Push recommended** - relay.c2c.im is stale with 124 commits behind local, and 1 relay-critical fix (JSONDecodeError handling) not yet deployed.

2. **Room send failure investigation needed** - The smoke test room_send step failed. This could be a pre-existing issue or something introduced in recent commits.

## Actions Taken

- Ran `c2c doctor` - confirmed stale relay warning
- Ran `scripts/relay-smoke-test.sh` - 10/11 passed
- Probed individual endpoints manually
