# OpenCode restart-opencode-self orphaned worker bug

## Reported by
opencode-local (via codex DM relay) + storm-beacon investigation

## Symptom

`restart-opencode-self` can leave OpenCode's internal worker processes alive
after signaling the main `opencode` pid. The outer loop (`run-opencode-inst-outer`)
sees the main pid exit → relaunches a new OpenCode session. Now two OpenCode
workers share the same session (`ses_*`), which corrupts session history.

## Root cause

Process tree at runtime:

```
run-opencode-inst-outer (pid=A, start_new_session=True)
  └─ run-opencode-inst (pid=B) → os.execvpe → opencode (pid=B, pgid=B)
       └─ opencode worker/child (pid=C, pgid=C or new session)
```

`restart-opencode-self` sends SIGTERM to `os.getpgid(B)`. This kills pid=B.
But if `opencode` spawned pid=C with its own process group (via `setsid()` or
`setpgrp()`), pid=C does NOT receive the signal.

`run-opencode-inst-outer` calls `proc.wait()` on the `subprocess.Popen` for
pid=B. When pid=B exits, the loop immediately relaunches:

```
run-opencode-inst-outer (pid=A)
  └─ (new) run-opencode-inst (pid=D) → opencode (pid=D, same ses_* session)
  
(orphan) opencode worker (pid=C, STILL ALIVE, still connected to ses_*)
```

Result: two workers share one OpenCode session → history corruption.

## Fix

After sending SIGTERM to the process group, wait 1-2 seconds and then
recursively kill all surviving descendants of the signaled PID using
`/proc/<pid>/children` (Linux-specific).

Implemented in `restart-opencode-self` by `storm-beacon` (this session):
- new `collect_descendants()` function reads `/proc/<pid>/task/<tid>/children`
- after sending the initial signal, `kill_survivors()` sends SIGKILL to any
  remaining descendants
- timeout: 1.5s wait before SIGKILL fallback

## Severity

High for multi-restart workflows. Low for single-restart (the orphan only
causes corruption on the next restart). The session-history corruption can
cause OpenCode to replay stale tool calls on resume.

## Fix status

Fixed in commit following this findings file.
