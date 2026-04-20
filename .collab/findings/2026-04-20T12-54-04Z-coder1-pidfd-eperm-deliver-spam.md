# pidfd_getfd EPERM spam from `c2c start` deliver daemon

**Date**: 2026-04-20 12:54 UTC
**Reporter**: coder1 (via Max → coordinator1 bug report)
**Severity**: MEDIUM — non-fatal (MCP path still works for Claude Code via PostToolUse hook), but degrades UX and silently disables PTY wake for Kimi/OpenCode.

## Symptom

`c2c start claude` (and other clients) spawn `c2c_deliver_inbox.py --loop`. Per
inbox event the daemon prints:

```
[c2c-deliver-inbox] [Errno 1] pidfd_getfd returned EPERM — the Python
interpreter likely lacks CAP_SYS_PTRACE. Run e.g.
`sudo setcap cap_sys_ptrace=ep
/home/linuxbrew/.linuxbrew/Cellar/python@3.14/3.14.2_1/bin/python3.14`
(or raise kernel.yama.ptrace_scope restrictions).
```

In `--loop` mode the same error reprints per message, clogging the
deliver-daemon log.

## Root cause

- `kernel.yama.ptrace_scope = 1` on host (CachyOS default).
- Both candidate interpreters lack the capability:
  - `/home/linuxbrew/.linuxbrew/Cellar/python@3.14/3.14.2_1/bin/python3.14` — no caps.
  - `/usr/bin/python3.14` — no caps.
- `c2c_pty_inject._pidfd_getfd` raises `PermissionError` on EPERM
  (`c2c_pty_inject.py:227-234`), `c2c_deliver_inbox.main` catches and prints
  once per iteration (`c2c_deliver_inbox.py:549-551`).

## Fix plan

1. **Preflight probe in `c2c start`** — cheap `pidfd_getfd(self_pidfd, 0)` test
   at outer-loop start. On EPERM print a single actionable banner with the exact
   setcap command for `sys.executable`. Continue in degraded mode.
2. **Rate-limit in deliver loop** — `printed_once` guard inside
   `c2c_deliver_inbox.run_loop` so `PermissionError` from `inject_payload` prints
   once then silently increments a counter. Mirror in `c2c_poker.py`.
3. **New helper command `c2c setcap`** — resolves `/proc/self/exe`, prints the
   exact setcap invocation, and with `--apply` execs `sudo setcap ...`
   (interactive password prompt).

## Deferred

- Auto-sudo in `c2c install` — too risky without explicit user consent per-run.
- `/dev/pts/<N>` slave-side write fallback — per `c2c_pts_inject.py` docstring
  and CLAUDE.md Kimi note, slave writes display but don't submit, so this is
  not a real delivery path.

## Status

- [x] Investigated
- [x] DM'd coordinator1 with approach for relay to Max (2026-04-20T12:53Z)
- [ ] Approach approved
- [ ] Layer 1 implemented (preflight banner)
- [ ] Layer 2 implemented (rate-limit)
- [ ] Layer 3 implemented (`c2c setcap` helper)
- [ ] Tested end-to-end

## Notes for next agent

- If `getcap` shows the cap IS set on `/usr/bin/python3.14` but the error
  persists, check that `c2c_start.py` is actually launching the capped
  interpreter (linuxbrew python takes PATH precedence here — the shebang
  `#!/usr/bin/env python3` resolves to linuxbrew first).
- Setcap does not survive python package upgrades; document in CLAUDE.md that
  `c2c setcap` may need re-running after `brew upgrade python@3.14`.
