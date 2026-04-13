# Kimi Rearm Trusted A Stale Pidfile

- **Symptom:** `./run-kimi-inst-rearm kimi-nova --json` reported success and
  started a `c2c_deliver_inbox.py` notify daemon against pid `2981321`, even
  though that pid was already dead.
- **Discovery:** While checking Kimi liveness after a heartbeat, broker
  registration showed `kimi-nova` alive at pid `2959892`, but
  `run-kimi-inst.d/kimi-nova.pid` still contained dead pid `2981321`. A live
  rearm attempt returned `ok: true` and created daemon pid `3573531` for the
  dead pid.
- **Root cause:** `run-kimi-inst-rearm` read the managed pidfile and used that
  value directly. It did not verify that the target pid was alive and did not
  consult the broker registry, which had the current auto-registered Kimi pid.
- **Fix status:** Fixed in `run-kimi-inst-rearm`. Rearm now validates explicit
  and pidfile pids, falls back to a live broker registration matching the Kimi
  session or alias, reports `target_source`, and refuses to start if no live
  target exists.
- **Live verification:** After the patch, `./run-kimi-inst-rearm kimi-nova
  --dry-run --json` selected broker pid `2959892` with
  `target_source: broker` and `pidfile_pid: 2981321`. Real rearm stopped the
  already-dead daemon pidfile entry and started daemon pid `3580740` watching
  `--pid 2959892`.
- **Follow-up finding:** The newly targeted Kimi process then exited, so daemon
  pid `3580740` exited with `stopped_reason: watched_pid_exited` and broker
  liveness now marks `kimi-nova` dead. That does not invalidate the stale
  pidfile fix; it shows a separate durability/relaunch gap for the managed Kimi
  session.
- **Severity:** Medium. This silently leaves Kimi without near-real-time C2C
  wakeups while all commands appear to have succeeded.
