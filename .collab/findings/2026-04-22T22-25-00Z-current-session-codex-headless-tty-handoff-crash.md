## Symptom

Managed `c2c start codex-headless` under tmux could drain broker messages without ever
showing output or persisting `resume_session_id`. In an escalated repro with stderr
captured, the bridge panicked:

`failed to wake I/O driver: Os { code: 9, kind: Uncategorized, message: "Bad file descriptor" }`

## How I Found It

- Confirmed broker drain/archive/spool all completed for the headless session.
- Verified `codex-turn-start-bridge` works directly with both plain text XML payloads and
  the exact c2c `<message><c2c ...>` payload, including `--thread-id-fd 5`.
- Reproduced the failure only through the managed launcher path when stdin was initially a
  tty/tmux pane before being swapped to the broker-owned pipe.
- A non-tmux managed repro (`c2c start codex-headless` with stdout/stderr redirected and
  no tty stdin) stayed alive instead of panicking.

## Root Cause

`ocaml/c2c_start.ml` was treating `codex-headless` like an interactive TUI client and
calling `tcsetpgrp` before swapping stdin to the broker pipe. `codex-headless` is not a
human-stdin client; that foreground-tty handoff only exists for TUIs like OpenCode. The
headless bridge needs pipe-owned stdin and should not participate in tty foreground-group
management.

## Fix Status

In progress: special-cased `codex-headless` to skip tty foreground handoff in the child
launch path and documented why in the code. Live repro + E2E rerun still pending after the
patch.

## Severity

High. This blocks the primary managed `codex-headless` delivery path in tmux/live testing.
