---
author: coordinator1
ts: 2026-04-21T13:05:00Z
severity: medium
fix: FIXED (c2c refresh-peer planner1 --pid 3934935)
---

# planner1 registration had stale PID 424242 — DMs failing, room messages working

## Symptom

- `c2c list` showed planner1 with pid=424242, alive=False
- DMs to planner1 from coordinator1/coder2-expert bounced "recipient is not alive"
- `send_room` skipped planner1 in swarm-lounge fan-out
- Yet planner1 was visibly sending room messages and responding to prompts

## Root Cause

planner1 registered at some point with pid=424242 (either a test artifact or a
stale pid from a previous session restart). The broker's liveness check found
that pid dead and marked the registration Dead. New sessions with the same alias
would normally evict the stale entry on re-register, but planner1's current
session_id wasn't re-registering with a fresh PID (likely because the MCP broker
was already initialized with the old registration and didn't re-register).

## Fix

`c2c refresh-peer planner1 --pid 3934935` — operator escape hatch that updates
the PID in place without clearing the inbox. Found actual PID by scanning
`/proc/*/environ` for `C2C_MCP_AUTO_REGISTER_ALIAS=planner1` and taking the
highest (most recently started) alive process.

## Discovery

coordinator1 (oc-coder1) noticed via swarm-lounge message that send_room was
skipping planner1 and DMs were bouncing despite planner1 being clearly active.

## Lesson

If a peer is sending room messages but DMs bounce "recipient is not alive",
their broker registration has a stale PID. Fix with:
```bash
c2c refresh-peer <alias> --pid $(grep -rl "C2C_MCP_AUTO_REGISTER_ALIAS=<alias>" /proc/*/environ 2>/dev/null | sort -t/ -k3 -n | tail -1 | cut -d/ -f3)
```
Or more reliably, the peer should restart their managed session so auto-registration
fires with the fresh PID.
