---
author: coordinator1
ts: 2026-04-21T07:36:00Z
severity: medium
fix: not-started
---

# c2c start leaves no forensic trace when inner client dies

## Symptom

opencode-test (managed instance) exited code=1 after 13958.3s. Pane
scrollback shows only:

```
[c2c-start/opencode-test] inner exited code=1 after 13958.3s
resume via: c2c start opencode -n opencode-test
```

No instance dir, no stdout/stderr log, no crash dump. Root cause cannot
be diagnosed after the fact.

## Discovery

Max asked "why did it die?" at 07:36 local on 2026-04-21. Investigation
showed `~/.local/share/c2c/instances/opencode-test/` does not exist.
The outer loop cleaned up state on exit. Only the pane buffer retained
the exit message, and that's ephemeral.

## Root cause

`c2c_start.ml` `cmd_stop` / outer-loop cleanup removes the instance
state directory unconditionally when the managed client exits
non-zero. Stdout/stderr of the inner client is bound to the PTY and
never tee'd to a file.

## Impact

- Can't distinguish plugin crash vs TUI crash vs API error vs OOM.
- Session-death diagnosis requires live `tmux capture-pane -S -999`
  before the operator clears the pane.
- Swarm loses a participant silently; the coordinator has no signal
  other than "alias went dead in registry."

## Proposed fix

1. **Persist a ring-buffer log.** In `c2c_start.ml`, tee the inner
   client's stderr to `<instance_dir>/stderr.log` (capped at ~2MB,
   rotated). Keep on non-zero exit.
2. **Keep instance dir on error exit.** Only remove on clean exit
   (code 0) and on explicit `c2c stop <name>`. Non-zero exit retains
   the last config + log for 24h.
3. **Emit structured death event.** On inner exit, write
   `<broker>/deaths/<name>-<ts>.json` with {name, client, exit_code,
   duration_s, last_50_stderr_lines}. Coordinator/supervisors can
   subscribe.
4. **Surface in `c2c instances`.** Add a `--with-deaths` flag that
   lists recent non-zero exits with root-cause hints.

## Workaround (now)

When an operator notices a dead managed session, `tmux capture-pane -t
<pane> -p -S -999 > /tmp/death.log` BEFORE restarting it. Forward to
`.collab/findings/` for offline analysis.

## Related

- `.collab/findings/2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md`
  — adjacent failure mode (blocked on dialog, not exited).
- Group goal: swarm aliveness depends on fast death diagnosis. Silent
  deaths with no forensics are a protocol crinkle to iron out.
