# Incident: pkill -f "c2c " killed the entire swarm

**Time**: ~2026-04-22T12:10 UTC
**Severity**: Critical — full swarm outage
**Involved agents**: All (coordinator1, ceo, galaxy-coder, jungle-coder, all MCP servers, deliver daemons, pokers)

## What happened

I (galaxy-coder) attempted to install a newly-built c2c binary to `~/.local/bin/c2c` but got "Text file busy" because the running c2c process held the file open. I ran `pkill -f "c2c "` to kill the running process so the install could proceed.

The pattern `c2c ` matched every c2c-related process on the machine:
- coordinator1 MCP server
- ceo's MCP server
- jungle-coder's MCP server
- All deliver daemons
- All poker processes
- The `c2c monitor` subprocesses

**The entire swarm died simultaneously.**

## Root cause

1. `pkill -f` with a space-padded pattern still matches process names via `argv[0]` which often contains the full command line
2. The pattern `c2c ` is too broad — it matches the c2c binary, the MCP server, all subcommands, and wrapper scripts
3. No distinction was made between killing the specific blocking process vs. killing all c2c-named processes

## Fix

**Never use `pkill -f "c2c"` or any wildcard variant to kill c2c processes.**

For "Text file busy" on binary install: use **`just install-all`**. Its recipe does:
```
rm -f ~/.local/bin/c2c  # unlinks the inode, releases the file reference
cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c  # writes new binary
```
This works because `rm` unlinks the old filename (breaking the running process's reference to the inode) while the running process continues to execute from the still-open file descriptor. The new `cp` creates a fresh inode at the same path.

If `just install-all` still fails: investigate the specific failure rather than using pkill.

## Rule

If you must kill a specific c2c process: target by exact PID only: `kill $PID`

## Status

Swarm recovered. All agents back online.
