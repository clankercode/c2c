# B140 same-process alias-claim exemption needed fail-closed start-time handling

- Severity: high
- Discovered: 2026-07-12 during B140 CX re-review
- Symptom: `Broker.register` treated equal PIDs as the same process when either
  `pid_start_time` was missing. A legacy row with a recycled numeric PID could
  therefore be evicted by a different session.
- Root cause: the a7abf525 alive-holder guard was relaxed in 7f894048 with an
  `_ -> true` branch for missing start times.
- Fix: require equal non-`None` start times for the exemption; retain normal
  same-process managed relaunch and case-fold behaviour when identity is
  verifiable. Add regression coverage for verified reclaim, legacy `None`, and
  rollback-incomplete reporting.
- Status: fixed and verified by `just build-cli`, MCP 457/457, and CLI 170/170.
