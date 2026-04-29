# Finding: poll-inbox returns empty from peer-b/peer-c containers (#310)

## Date
2026-04-27

## Context
Working on #310 multi-container Docker E2E. Two-container tests pass.
Four-container mesh test (4 clients, 6 ordered-pair DMs) fails:
- alice→bob/carol/dave: PASS (alice in peer-a)
- bob→carol/dave: FAIL (bob in peer-b)
- carol→dave: FAIL (carol in peer-c)

## Key Observations

### 1. Messages ARE in the inbox files
When checking inbox files directly via `cat /var/lib/c2c/{session}.inbox.json`
from any container, the messages ARE present:
```
carol inbox (from peer-a): [{'from_alias': 'alice-...', ...}, {'from_alias': 'bob-...', ...}]
dave inbox (from peer-a): [{'from_alias': 'alice-...', ...}, {'from_alias': 'bob-...', ...}, {'from_alias': 'carol-...', ...}]
```

### 2. poll-inbox returns [] from peer-b/peer-c
When `poll_for_msg` polls from peer-b (for bob) or peer-c (for carol),
it returns `[]` even though the inbox file contains messages.

### 3. poll-inbox works from peer-a
When polling from peer-a (alice's container), messages appear correctly.

### 4. Two-container test polls from peer-b and PASSES
`test_two_container_dm_alice_to_bob` polls bob's inbox from peer-b
using the same env vars and same poll-inbox command. It passes.

### 5. Direct file read from peer-b also works
When checking the inbox file directly from peer-b's container,
the messages appear. Only poll-inbox returns empty.

## Hypothesis
The issue is NOT with message delivery (messages ARE written to the correct
inbox files). The issue is with `poll-inbox` when called from peer-b/peer-c
containers in the specific timing/sequence of the mesh test.

Possible causes:
- poll-inbox resolves the session ID differently under certain conditions
- The broker root resolution differs between containers in specific contexts
- File locking / visibility issues with the inbox lock file

## What's NOT the issue (ruled out)
- Registration timing: all registrations complete before any sends
- Broker root: all containers use C2C_MCP_BROKER_ROOT=/var/lib/c2c consistently
- Lease TTL: TTL=300s covers the test duration
- Message delivery: inbox files contain messages correctly
- Container networking: all containers share the same volume

## Current Workaround
Using direct file read (`cat /var/lib/c2c/{session}.inbox.json`) instead of
`poll-inbox --json` makes the mesh test pass.

## Status
Open - root cause not yet identified. Need to add debug output to poll-inbox
binary and rebuild Docker image to trace what session ID / broker root it resolves.
