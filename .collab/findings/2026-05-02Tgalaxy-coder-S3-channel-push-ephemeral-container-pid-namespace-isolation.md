# S3 channel-push test: ephemeral container PID namespace isolation bug

**Date**: 2026-05-02
**Agent**: galaxy-coder
**Topic**: #406 S3 channel-push test / Docker test infrastructure
**Severity**: High (blocks test implementation)

## Finding Summary
When the channel-push test uses ephemeral Docker containers (`docker run --rm`)
for both the client and sender, the send operation fails with "recipient is
not alive" because the sender cannot verify the client's liveness.

## Root Cause
Ephemeral containers created by `docker run --rm` have **isolated PID
namespaces** — a process in container A cannot see `/proc/<pid>` of a
process in container B, even when they share a volume.

The c2c broker uses two liveness mechanisms:
1. `/proc/<pid>` checks (non-Docker mode)
2. File-based lease files in `.leases/` directory (Docker mode,
   activated by `C2C_IN_DOCKER=1`)

In Docker mode:
- Registration creates a lease file at `.leases/<session_id>` with recent mtime
- `registration_is_alive` checks if the lease file's mtime is within TTL
- This works across containers sharing the same broker volume

BUT: the liveness check requires BOTH endpoints to be in Docker mode. If the
SENDER is in an ephemeral container that does NOT have `C2C_IN_DOCKER=1` in
its environment, it uses `/proc` liveness, which fails because the client's
PID is not visible.

## Discovery Timeline
1. Initial test used `docker run --rm` for client, passed `C2C_MCP_SESSION_ID`
   to the ephemeral sender, causing the CLI to auto-register with a different
   PID (persistent sleep, PID 7) than the client's PID → "not alive"
2. Removed `C2C_MCP_SESSION_ID` from sender → still fails, now because
   ephemeral containers don't have `C2C_IN_DOCKER=1` in their env
3. Added `C2C_IN_DOCKER=1` to sender's env → still fails because the
   client's lease file isn't visible (client is in yet another ephemeral
   container with isolated PID namespace)
4. Tried `docker exec -d` to run client inside persistent peer-b → shell
   redirection `> file 2>&1` fails silently with `-d` flag, client never
   actually runs

## What DOES Work
When both the client and sender are in the SAME container (verified via
ad-hoc manual test), send + notification delivery works correctly:
- Client registers, creates lease file
- Sender finds lease, marks recipient alive
- Send succeeds, notification arrives

## Potential Fixes
1. **Run client as persistent service in peer-b**: Don't spawn ephemeral
   container for client; instead run the Python script as a long-running
   process inside the persistent peer-b container. Use `docker exec` (not
   `-d` detached) with proper output capture via named pipe or socket.
2. **Single-container topology**: Put both client and sender in the same
   container (peer-a for sender, persistent peer-b for both client and broker)
3. **Skip liveness check in tests**: Add a test mode that bypasses liveness
   verification for send (not desirable — changes production behavior)

## Files Changed
- `docker-tests/channel_push_client.py`: Python MCP client stub
- `docker-tests/test_s3_channel_push.py`: pytest test (WIP)

**Commit**: `9a2e0eec` (wip: S3 channel-push test scaffolding)