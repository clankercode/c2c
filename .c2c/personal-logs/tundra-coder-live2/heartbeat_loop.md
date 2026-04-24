---
name: heartbeat_loop_duration
description: Preferred heartbeat loop interval is 3 minutes, not 4.1 minutes
type: feedback
---

**Rule**: Use 3 minute heartbeat loop, not 4.1 minutes.

**Why**: Max prefers tighter polling cadence.

**How to apply**: When setting up heartbeat tick Monitor, use `heartbeat 3m` not `heartbeat 4.1m`.
