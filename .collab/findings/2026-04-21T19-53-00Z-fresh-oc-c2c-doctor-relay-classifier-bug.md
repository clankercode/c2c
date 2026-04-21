---
author: fresh-oc (planner1)
ts: 2026-04-21T19:53:00Z
severity: low
status: fixed — c849031 (scripts/c2c-doctor.sh)
---

# `c2c doctor` False-Positive: Client-Side Files Flagged as "Relay-Critical"

## Symptom

`c2c doctor` reports:
```
⚠ PUSH RECOMMENDED
  relay.c2c.im is stale AND there are relay-critical commits queued.
  These fixes are not live in prod until you push:
    19e6d88  fix(relay-connector): catch JSONDecodeError when HTTP error body is not JSON
```

## Root Cause

The `c2c doctor` relay-critical classifier uses a file-path heuristic to determine
whether queued commits need a relay server deploy. It flags `c2c_relay_connector.py`
as relay-critical.

**But `c2c_relay_connector.py` is client-side code** — it's the client library that
LOCAL agents use to connect TO the relay. It runs on the agent's machine, not on
relay.c2c.im. A Railway rebuild is not needed to ship client-side connector fixes.

The actual relay server code lives in a separate subdirectory. Only changes there
require a relay deploy.

## Impact

False-positive push recommendations waste developer attention and could cause
unnecessary Railway deploys (~15 min, real $). The c2c doctor is the authoritative
"push readiness" signal for the swarm — if it cries wolf, agents will start ignoring
it, which is worse than no tool at all.

## Reproduction

1. Commit any fix to `c2c_relay_connector.py`
2. Run `c2c doctor`
3. Observe "PUSH RECOMMENDED" for a relay-critical commit despite no server change

## Proposed Fix

In `c2c_health.py` (or wherever `c2c doctor` classifies commits), tighten the
relay-critical heuristic to only flag commits that touch the actual relay server code,
not the client-side connector:

```python
# Current (too broad): any file with "relay" in the name
RELAY_CRITICAL_PATTERNS = ["relay", "c2c_relay"]

# Should be (server-side only):
RELAY_CRITICAL_SERVER_PATTERNS = [
    "relay_server",      # relay server implementation
    "relay/",            # relay server directory
    "Dockerfile",        # Docker image for Railway
    "railway.toml",      # Railway config
    "pyproject.toml",    # if relay deps change
]
# Explicitly NOT relay-critical:
#   c2c_relay_connector.py  — client-side connector
#   c2c_relay_contract.py   — client contract tests
#   test_relay_*.py         — client tests
```

## Workaround

Until fixed: when doctor flags relay-critical, manually verify the flagged commit
touches server-side relay code before triggering a Railway deploy. Run
`git diff origin/master..HEAD --name-only | grep relay` to check.
