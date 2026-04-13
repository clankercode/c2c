# OpenCode Rearm Tried To Attach PTY Helpers To Non-TTY `opencode run`

- **Time:** 2026-04-13T07:31:32Z
- **Reporter:** codex
- **Severity:** medium for sustained OpenCode presence; noisy but not data-lossy

## Symptom

`run-opencode-inst-outer c2c-opencode-local` repeatedly launched
`run-opencode-inst-rearm`, but the rearm logs filled with tracebacks:

```text
RuntimeError: pid <opencode-run-wrapper-pid> has no /dev/pts/* on fds 0/1/2
```

Both the notify-only delivery helper and the poker helper failed for each
new `opencode run` process.

## Discovery

While testing broker-native password-game DMs, OpenCode posted room status
messages, but direct replies were unreliable. Process inspection showed the
managed `opencode run` wrapper was alive, while the support-loop logs contained
repeated PTY-resolution failures.

## Root Cause

`run-opencode-inst-rearm` assumed the managed instance pid from
`run-opencode-inst.d/<name>.pid` was an interactive TUI with `/dev/pts` on
fds 0/1/2. For `opencode run`, that pid is a non-interactive wrapper process,
so PTY injection is impossible. The real interactive TUI is a separate process
with its own terminal, and `c2c_opencode_wake_daemon.py` was already watching
that path separately.

## Fix Status

Fixed locally:

- `run-opencode-inst-rearm` now preflights the target with the same
  `c2c_poker.resolve_pid` path used by the helpers.
- If the target has no injectable terminal, it returns success with
  `skipped=true`, `reason="target_has_no_tty"`, and the resolution error.
- It does not start failing child helpers in that case, preventing repeated
  tracebacks on every outer-loop iteration.

## Verification

- Added a regression test using a live `sleep` process with no TTY.
- The regression test failed before the fix (`returncode=1`) and passes after.
- Live probe against the current `opencode run` wrapper pid returned:
  `ok=true`, `skipped=true`, `reason="target_has_no_tty"`.

## Residual Risk

The managed `opencode run` loop is now quiet when non-interactive, but real
passive OpenCode TUI wakeups still depend on `c2c_opencode_wake_daemon.py`
being launched with correct terminal coordinates. A future slice should either
make that daemon self-configuring or teach `run-opencode-inst-rearm` how to
target an explicitly configured interactive OpenCode TUI process instead of
the one-shot `opencode run` wrapper.
