---
title: ECHILD root cause — c2c start leaked SIGCHLD=SIG_IGN into managed Claude Code via execve
date: 2026-04-20T14:01:05Z
author: coder2-expert
severity: high — every host Claude Code session launched via `c2c start` had broken waitpid() for hooks
---

# Symptom

Even after fixing the two hook-body regressions (canonical `c2c hook;
exit 0` body in `~/.claude/hooks/c2c-inbox-check.sh` + cache-side
idle-info sleep wrapper — see
`2026-04-20T12-57-10Z-coder2-expert-echild-hook-regressions.md`),
Claude Code continued to emit:

```
PostToolUse:Bash hook error — Failed with non-blocking status code:
  Error occurred while executing hook command: ECHILD: unknown error, waitpid
PostToolUse:Grep hook error — …
Stop hook error — …
```

Bumping `min_hook_runtime_ms` from 50→100ms (commit 1c82e8c) reduced
but did not eliminate the rate. Symptom also hit pure-sleep stub
hooks that did zero work, which ruled out anything we were doing
inside `c2c hook`.

Max's key insight (verbatim): *"if the idle timing plugin is causing
issues it's because we're interfering with it or something. it does
not cause issues outside c2c."* That redirected the search from hook
bodies to how the host Claude process got spawned.

# Root cause

`c2c start` (ocaml/c2c_start.ml) installs `SIGCHLD = SIG_IGN` in its
own process around line 488 so the sidecars (deliver daemon, poker)
get auto-reaped by the kernel without explicit `waitpid`. That
disposition is then *inherited across execve* into the managed
client (Claude Code) because POSIX preserves SIG_IGN on exec (only
handler-installed dispositions are reset).

Check:

```
$ grep -E '^Sig(Ign|Cgt):' /proc/<claude_pid>/status
SigIgn: 0000000000011000   ← bit 16 (SIGCHLD) + bit 12 (SIGPIPE)
SigCgt: 000000017b826cff
```

Bit 16 = signal 17 = SIGCHLD. Under SIG_IGN, the kernel reaps
finished children automatically, so any later `waitpid(pid)` call
returns ECHILD because the child is already gone from the process
table. Node.js/libuv's hook runner relies on waitpid to collect the
hook child; when it loses the race to the kernel's auto-reap, it
surfaces `ECHILD: unknown error, waitpid` on stderr and reports the
hook as failed even though the script exited 0.

This is a classic POSIX footgun — SIG_IGN on SIGCHLD is functionally
"discard child exit status" and is well-known to interact badly with
any code that expects to wait() for its children. Every Claude Code
session spawned via `c2c start` inherited this broken disposition,
which is why no amount of hook-body tuning helped.

# Fix (commit d4413bd)

Replaced the `Unix.create_process_env` call for the managed client
in `ocaml/c2c_start.ml` (~line 555) with a manual fork + signal
reset + exec:

```ocaml
let child_pid_opt =
  try
    let pid = match Unix.fork () with
      | 0 ->
          (try ignore (Sys.signal Sys.sigchld Sys.Signal_default) with _ -> ());
          (try ignore (Sys.signal Sys.sigpipe Sys.Signal_default) with _ -> ());
          (try Unix.execvpe binary_path (Array.of_list cmd) env
           with e ->
             Printf.eprintf "exec %s failed: %s\n%!" binary_path (Printexc.to_string e);
             exit 127)
      | p -> p
    in
```

The parent (c2c start) keeps its SIG_IGN so sidecars still get
auto-reaped; only the managed-client child gets SIG_DFL before exec.
This is the standard fix for inherited-SIG_IGN bugs — you can't use
`Unix.create_process*` because those don't expose a pre-exec hook in
the child, you need raw fork+exec.

# Verification

After the staggered swarm restart (coder1 → planner1 → coder2-expert),
each restarted session shows:

```
$ grep -E '^SigIgn:' /proc/<new_claude_pid>/status
SigIgn: 0000000000001000   ← only SIGPIPE, no SIGCHLD
```

ECHILD hook errors stopped immediately on restarted panes. The pre-
restart pane (coordinator1, SigIgn=0x11000) still saw them until
self-restart.

# Follow-ups

- The SIG_IGN at c2c_start.ml:488 is still the right choice for the
  parent's own lifecycle management — don't "fix" it there; the fix
  belongs at the fork site, not at the sidecar handler.
- Worth adding a runtime assertion at c2c-start that checks its
  child's SigIgn after spawn and warns if SIGCHLD is still ignored,
  so a future regression of the fork+exec path gets caught
  immediately rather than manifesting as stochastic hook breakage
  in all host clients.
- The `Unix.create_process_env` function is still used elsewhere in
  the codebase for launching sidecars — those paths are fine because
  sidecars don't run hooks. But any future "launch a managed client"
  path must use the fork+exec+reset pattern, not create_process. A
  helper function `spawn_with_default_signals` would make this less
  footgunny; worth adding if we grow another managed-client launcher.
- Document this in CLAUDE.md so future agents debugging ECHILD don't
  retrace the hook-body rabbit hole.

# Related

- `2026-04-20T12-57-10Z-coder2-expert-echild-hook-regressions.md` —
  the two hook-body regressions that were fixed first but didn't
  actually solve the symptom
- `2026-04-19T09-08-00Z-opus-host-posttooluse-hook-echild-race.md` —
  original finding, which only treated the surface symptom
- Commits: d4413bd (root fix), 1c82e8c (mitigation bump), f47d3ed
  (hook-body regressions)
- POSIX signal inheritance across exec: signals with
  `Signal_default` or `Signal_ignore` disposition are preserved;
  only `Signal_handle` is reset to default. SIGCHLD=SIG_IGN has the
  special effect of auto-reaping children, which conflicts with any
  wait()-based child management downstream.
