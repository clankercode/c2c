# smoke-113 exit path bug — 2026-04-24T09:51:00Z

## Symptom
- `c2c start codex -n smoke-113` launched in tmux
- codex ran fine for ~16 min
- Sent `/exit` — codex TUI exited cleanly ("To continue this session, run codex resume...")
- Actual process (pid 2758570, /home/xertrov/.local/bin/c2c start codex -n smoke-113) is DEAD (ps confirms)
- `c2c instances` STILL shows smoke-113 as "running xml_fd (pid 2758570)" — stale registry

## Root Cause
c2c_start wrapper process exits but instance registry entry is never cleaned up.
This is the #113 bug (tee shutdown / instance cleanup) manifesting at exit time.

## How Discovered
Smoke test per coordinator1's instructions.

## Fix Status
**PASS — #113 is fixed.**

Timing: /exit → wrapper dead in <2s (near-instant, not 60s+). The 720f903 tee
shutdown ordering fix is working correctly. Wrapper Thread.join now returns.

Instance registry DID update — showed "running" then "stopped" after poll. The state
machine is functional; not completely frozen.

## Follow-up
Coordinator1 filed #147 for registry cleanup on clean exit. Observed that state
does update to "stopped" (not truly stale), but stopped entries may accumulate
forever. Clarifying scope with coordinator1.
