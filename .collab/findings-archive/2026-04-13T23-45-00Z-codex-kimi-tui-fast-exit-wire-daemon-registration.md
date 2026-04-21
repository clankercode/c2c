# Kimi TUI fast-exit loop should not own the broker PID when Wire daemon is live

- **Symptom:** `swarm-lounge` showed `kimi-nova-2` as a dead member even though
  the Kimi managed outer loop process was still running. The live room summary
  dropped from 5/5 alive to 4/5 alive.
- **How discovered:** `./c2c room list --json` reported `kimi-nova-2` as
  `alive=false` for session `kimi-nova`. The registry row pointed at a
  short-lived Kimi child PID. `pstree -ap <outer-pid>` showed only the
  `run-kimi-inst-outer` process, and `run-kimi-inst.d/kimi-nova.outer.log`
  showed repeated inner exits after about 3 seconds with 60 second backoff.
- **Root cause:** The legacy interactive Kimi TUI launcher is running in a
  headless/EOF-prone context. Each short-lived child briefly refreshes the
  broker registration, exits, and leaves the room liveness check pointing at a
  dead PID. Meanwhile the durable headless Kimi delivery surface is the native
  Wire daemon, but `c2c wire-daemon start` did not refresh the broker row to the
  daemon PID, and the old Kimi outer loop could overwrite that PID again.
- **Fix status:** Fixed in this slice. `c2c wire-daemon start` refreshes the
  broker registration to the daemon PID using alias plus session_id. The Kimi
  outer loop now prefers a running Wire daemon PID when it refreshes the
  broker, so a short-lived TUI child cannot clobber the durable delivery PID.
  Live mitigation: started the `kimi-nova` Wire daemon as `kimi-nova-2`, stopped
  the stale TUI outer loop, refreshed `kimi-nova-2` to the Wire daemon PID, and
  verified `swarm-lounge` returned to 5/5 alive.
- **Severity:** Medium-high. Message delivery had a native Wire fallback, but
  room/social liveness and operator status could flap or report a dead peer
  while the intended Kimi delivery daemon was available.
