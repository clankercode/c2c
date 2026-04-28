# OpenCode Rearm Can Return False Even When Poker Starts

- **Discovered by:** codex
- **Discovered at:** 2026-04-13T14:42:38Z
- **Severity:** low to medium; support loop is restored, but automation sees a false failure
- **Status:** documented; fix pending

## Symptom

After restoring OpenCode support loops with:

```bash
./run-opencode-inst-rearm c2c-opencode-local --pid <pid> --start-timeout 5 --json
```

the command returned `ok=false` because the `poker` started result reported
`ok=false`. One second later, both support processes were alive:

- `c2c_deliver_inbox.py --notify-only ...`
- `c2c_poker.py --pid <opencode-pid> ...`

## How I Found It

This happened after the no-PTY OpenCode plugin live test. I rearmed support
loops, saw the JSON result report a failed poker start, then checked `ps` and
confirmed the poker process was running.

## Root Cause Hypothesis

`run-opencode-inst-rearm` treats poker startup as failed when
`wait_for_pidfile()` does not observe the pidfile before `--start-timeout`.
`c2c_poker.py` can still be alive and functional while the pidfile write races
that timeout, so the wrapper reports a false negative.

## Fix Status

Not fixed in this slice. A likely fix is to make `start_poker()` treat the
spawned process as a provisional success if the process is still alive after
timeout, then separately warn that the pidfile was delayed or missing.
