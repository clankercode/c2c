# Binary locked by own session — cannot install pty build

## Date
2026-04-25 UTC

## Problem
`cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c` fails with "Permission denied" because the running c2c process (test-agent, PID shown in `pgrep -a c2c`) has the binary open.

## Symptom
```
cp: cannot create regular file '/home/xertrov/.local/bin/c2c': Permission denied
```

Yet `touch ~/.local/bin/c2c` succeeds (no permission issue with directory).

## Root Cause
`~/.local/bin/c2c` is a running executable. On Linux, you cannot overwrite a running executable even as the owner.

## Workaround
1. Deploy from a different host/process that isn't using the binary
2. Coordinator1 (running on same machine) could deploy from their session
3. Or stop the session, deploy, restart

## Impact
Agents cannot self-update the binary while the session is running. Needs coordinator intervention or a restart from a different context.

## References
- AGENTS.md: "Restart yourself after MCP broker updates"
- `just install-all` recipe uses `rm -f` before `cp`, but rm fails on running binary