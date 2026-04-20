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

## Root cause (corrected)

Investigation (grep `rm|rmdir|rmtree` in c2c_start.ml and Python
scripts): **nothing in the codebase removes the instance dir on exit.**
`cleanup_and_exit` only removes pidfiles. The empty
`~/.local/share/c2c/` at diagnosis time was likely because
opencode-test predates a recent schema change, or was manually wiped.

The real gap is that the inner client's stdout/stderr is bound
directly to the outer's TTY and never tee'd to a file. Even if the
instance dir were populated, there'd be no log in it to diagnose.

## Impact

- Can't distinguish plugin crash vs TUI crash vs API error vs OOM.
- Session-death diagnosis requires live `tmux capture-pane -S -999`
  before the operator clears the pane.
- Swarm loses a participant silently; the coordinator has no signal
  other than "alias went dead in registry."

## Proposed fix

1. **Tee stderr to `<instance_dir>/stderr.log`.** Before `execvpe` in
   the child fork at c2c_start.ml ~L630, replace stderr with a
   `Unix.pipe` write-end. In parent, spawn a tiny reader thread that
   (a) writes to the inherited outer-stderr fd so user still sees TUI
   output, (b) appends to `<inst_dir>/stderr.log` (capped at 2MB with
   ring rotation). Keep file on exit.
2. **Emit structured death event.** On inner exit with code ≠ 0,
   append `<broker>/deaths.jsonl` entry: {name, client, exit_code,
   duration_s, last_50_stderr_lines}. Coordinator/supervisors can
   tail this.
3. **Surface in `c2c instances`.** Add `--with-deaths` flag that
   lists recent non-zero exits with the tail of their stderr.log.
4. **`c2c diag <name>`.** New subcommand: prints last death's
   stderr.log tail + exit code + elapsed time. Replaces the
   "run-before-clearing-pane" forensic dance.

## Workaround (now)

When an operator notices a dead managed session, `tmux capture-pane -t
<pane> -p -S -999 > /tmp/death.log` BEFORE restarting it. Forward to
`.collab/findings/` for offline analysis.

## Related

- `.collab/findings/2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md`
  — adjacent failure mode (blocked on dialog, not exited).
- Group goal: swarm aliveness depends on fast death diagnosis. Silent
  deaths with no forensics are a protocol crinkle to iron out.
