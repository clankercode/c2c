# Stale MCP Broker Binary + Crush Broker Orphan Leak

## Finding 1: Stale Broker Binary Causes Register Silent Drop

- **Symptom:** After fixing `Broker.register` fresh-entry bug in 3824610 and
  rebuilding the binary, my own MCP broker continued silently dropping fresh
  registrations. `register` returned `registered storm-beacon` (ok:true) but
  `d16034fc-5526-414b-a88e-709d1a93e345` never appeared in `registry.json`.
- **Root cause:** The MCP broker process (PID 3588458) was started at Unix time
  1776094016 — 11026 seconds **before** the binary was rebuilt at 1776105042.
  The running process has the OLD in-memory code. Rebuilding the binary on disk
  does not affect running processes. Only a restart picks up the new binary.
- **CLAUDE.md documents this rule:** "Restart yourself after MCP broker updates.
  The broker is spawned once at CLI start — new tools, flags, and version bumps
  are invisible until restart."
- **Fix:** Run `./restart-self` to spawn a fresh Claude Code session with a fresh
  MCP broker process using the rebuilt binary.
- **Severity:** High. The stale broker causes registration failures that look
  like success. `whoami` returns empty, messages to `storm-beacon` land in a dead
  session's inbox (or fail liveness check), and room fanout is silently broken.

## Finding 2: Crush Outer Loop Leaks MCP Broker Processes

- **Symptom:** 58 `c2c_mcp_server.exe` processes with
  `C2C_MCP_SESSION_ID=crush-xertrov-x-game` are running — all orphaned (PPid =
  systemd). Total across all sessions: 98 broker processes.
- **Root cause:** Each time `run-crush-inst-outer` starts a new Crush instance,
  Crush spawns a new MCP broker subprocess. When Crush exits, the broker process
  is reparented to systemd but does NOT exit. Its stdin pipe appears open (pipe
  write-end may still be held open by a parent or systemd). The process sleeps
  indefinitely waiting for JSON-RPC input.
- **Expected behavior:** When the Crush client exits, the write-end of the broker's
  stdin pipe should close, causing the broker to get EOF and exit cleanly. This is
  not happening — likely because `run-crush-inst-outer` or its process group is
  keeping the pipe write-end open, or because Crush does not properly close stdio
  before exiting.
- **Impact:** Medium. Each leaked broker holds ~5.5MB RSS. 58 processes = ~320MB
  leaked. This will grow indefinitely as the outer loop keeps restarting Crush.
  No functional impact on message delivery (these brokers are not serving any
  session).
- **Potential fix:** Add `setsid()` or `close_fds=True` in the Crush broker
  subprocess launch, or have `run-crush-inst-outer` explicitly kill the broker
  child before relaunching. Adding a broker PID to the pid tracking and killing it
  on outer-loop restart would prevent accumulation.
- **Workaround:** Manually kill orphaned brokers:
  ```bash
  # Kill Crush broker orphans (brokers whose Crush parent exited):
  pgrep -f "c2c_mcp_server" | while read pid; do
    ppid=$(awk '/PPid/ {print $2}' /proc/$pid/status 2>/dev/null)
    if [ "$ppid" = "$(pgrep systemd | head -1)" ]; then
      kill $pid
    fi
  done
  ```
