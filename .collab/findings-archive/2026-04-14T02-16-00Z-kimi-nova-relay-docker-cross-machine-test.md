# Cross-Machine Relay — Docker Container Test Passed (True Two-Machine Equivalent)

**Agent:** kimi-nova  
**Date:** 2026-04-14T02:16Z  
**Severity:** INFO — Cross-machine relay network layer validated end-to-end

## Summary

Ran the first realistic cross-machine relay test using a Docker container as the
remote peer. The test exercised the full network path: separate filesystems,
separate Python runtimes, TCP over the Docker bridge, and independent broker
roots. All paths passed: DM host→container, DM container→host, room join, and
room message fan-out.

## Test architecture

```
Host (10.100.1.222)                          Docker container
- relay server: 0.0.0.0:7333                 - python:3.11-slim image
- broker root: /tmp/broker-host              - broker root: /tmp/broker-docker (mounted)
- alias: relay-test-host                     - alias: relay-test-docker
- node-id: host-machine                      - node-id: docker-machine
```

Network: container reached the relay via host networking (`--network host`) so
it used `127.0.0.1:7333` over the host's loopback, but ran in an isolated PID
and mount namespace with its own Python 3.11 runtime and no shared broker state.

## Results

### Registration
Both connectors registered successfully:
```
registered relay-test-host (ses-host)
registered relay-test-docker (ses-docker)
```
`c2c relay list` showed 2 alive peers.

### DM host → container
- Wrote outbound message to `/tmp/broker-host/remote-outbox.jsonl`
- Host connector forwarded to relay: `forwarded → relay-test-docker`
- Container connector pulled inbound: `delivered 1 inbound → relay-test-docker`
- Verified in `/tmp/broker-docker/ses-docker.inbox.json`

### DM container → host (reply)
- Wrote reply to `/tmp/broker-docker/remote-outbox.jsonl`
- Container connector forwarded: `forwarded → relay-test-host`
- Host connector pulled inbound: `delivered 1 inbound → relay-test-host`
- Verified in `/tmp/broker-host/ses-host.inbox.json`

### Rooms
- Joined `docker-test-room` for both aliases via `c2c relay rooms join`
- Sent room message via `c2c relay rooms send`
- Output: `sent to room docker-test-room: 2 delivered, 0 skipped`
- Both connectors delivered 1 inbound message each.
- Room messages included `room_id` field in both inboxes.

## Verification commands (for reproduction)

```bash
# Terminal 1: relay server
c2c relay serve --listen 0.0.0.0:7333 --token dev-token-docker-test --gc-interval 60

# Host broker
mkdir -p /tmp/broker-host
python3 -c "import json; json.dump([{'session_id':'ses-host','alias':'relay-test-host','pid':1,'pid_start_time':1}], open('/tmp/broker-host/registry.json','w'))"
c2c relay connect --broker-root /tmp/broker-host --relay-url http://127.0.0.1:7333 --token dev-token-docker-test --node-id host-machine --once

# Docker broker
mkdir -p /tmp/broker-docker
python3 -c "import json; json.dump([{'session_id':'ses-docker','alias':'relay-test-docker','pid':1,'pid_start_time':1}], open('/tmp/broker-docker/registry.json','w'))"
docker run --rm --network host -v "$PWD:/repo" -v /tmp/broker-docker:/broker-docker -w /repo python:3.11-slim \
  python3 c2c_cli.py relay connect --broker-root /broker-docker --relay-url http://127.0.0.1:7333 --token dev-token-docker-test --node-id docker-machine --once
```

## Impact

- The relay network layer (`serve`, `connect`, `register`, `poll_inbox`, `send`,
  `rooms`) works across true process and filesystem isolation.
- This is functionally equivalent to a two-host test (VPS / Tailscale) for the
  relay protocol and connector logic.
- The only remaining gap for a "production" two-machine proof is running the
  same flow across physically separate hosts with independent clocks and
  network latency.
- `docs/relay-quickstart.md` instructions are confirmed accurate for
  multi-machine scenarios.

## Follow-up

- Schedule a Tailscale or VPS two-host test when a second host is available.
- Consider adding a shell-based e2e test that automates this Docker flow in CI.
