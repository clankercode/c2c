# Kimi PTY Wake Bug — `/dev/pts` Slave Writes Display Text But Do Not Submit

**Agent:** codex  
**Date:** 2026-04-13T16:12:18Z  
**Severity:** HIGH — Kimi idle wake can appear in the TUI without starting a turn

## Symptom

Max observed that Kimi PTY injection pastes or displays the wake text but does
not submit it. That matches the current Kimi `--client kimi` route through
`c2c_pts_inject.py`.

## How Discovered

After reading `c2c_kimi_wake_daemon.py`, `c2c_deliver_inbox.py`,
`c2c_inject.py`, and the live-proof finding, I ran a minimal pseudo-terminal
reproduction:

- A child process blocked on `stdin.readline()`.
- Parent wrote `slave_write\r\n` by opening the PTY slave path, same as
  `c2c_pts_inject.inject("/dev/pts/N", ...)`.
- The text appeared on the terminal side, but the child remained blocked.
- Parent then wrote `master_write\r\n` to the PTY master fd.
- The child immediately read the line and printed `GOT:master_write`.

Observed output:

```text
after slave write b'slave_write\r\r\n'
child return after slave write None
after master write b'master_write\r\n\r\nGOT:master_write\r\n\r\n<OSError 5>'
child return after master write 0
```

## Root Cause

`c2c_pts_inject.py` opens the PTY slave (`/dev/pts/<N>`) and writes to it.
For an interactive TUI, that is the display/output side, not keyboard input.
Writing there can make text visible in the terminal but does not deliver bytes
to the program's stdin. To simulate user input, c2c must write to the PTY
master side, which the existing `pty_inject` helper does via
`pidfd_open`/`pidfd_getfd`.

The previous "idle PTS live-proven" finding is likely over-attributed. A
subsequent room message from the same period notes that direct PTS did not
drain within 25s and that a later master-side `pty_inject` nudge with
`submit_delay=1.5` preceded the reply.

## Fix Status

Fixed in code. Kimi wake/inject delivery now routes through the master-side
`pty_inject` backend with a Kimi-specific default submit delay of 1.5 seconds,
not through `/dev/pts` slave writes. Longer-term, the Kimi Wire bridge should
replace PTY wake where possible.

## Live Verification

After the fix, `python3 c2c_deliver_inbox.py --client kimi --pid 3679625
--session-id kimi-nova --file-fallback --notify-only --notify-debounce 0
--json` resolved terminal owner `3725367` / `pts=0`, injected a notify-only
poll nudge through the master-side backend, and reported `notified: true`.

`kimi-nova.inbox.json` then drained from 2 queued room messages to 0 by the
fourth 3-second check. Message bodies stayed broker-native; only the poll
sentinel was PTY-injected.
