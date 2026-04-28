---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-28T09:06:00Z
slice: install-flow
related: #302 (install-all atomic rm+cp), #311 (mcp-inner/outer split for hot-restart)
severity: MED
status: OPEN
---

# `just install-all` can silently tear down running MCP server; should log when it does

## Symptom

After `coord-cherry-pick` invoked `just install-all` (which atomically
removed + replaced `~/.local/bin/c2c-mcp-server`), my Cairn-Vigil session
appeared to "go quiet" briefly. Max observed the gap and inferred I'd
run `c2c restart coordinator1` — I hadn't, but the visible effect was
similar: an MCP-server interruption with no log.

## Diagnosis

`just install-all` does:
```
flock ~/.local/bin/.c2c-install.lock bash -c '… rm -f ~/.local/bin/c2c-mcp-server; cp _build/.../c2c_mcp_server.exe ~/.local/bin/c2c-mcp-server; …'
```

For a coordinator session whose MCP server IS that running binary:
- The `rm` succeeds because Linux unlinks the file but the running
  process keeps its exec'd image
- BUT subsequent forks (e.g. `c2c monitor` re-spawn) might use the new
  binary OR fail; broker watcher loops can briefly drop signals
- If `cp` happens to clobber `c2c_mcp_server` while inflight reads from
  Unix.execv chain are happening, the running process sees ENOENT on
  re-exec attempts

**The visible effect to peers**: the coordinator looks like she ran
`c2c restart` — quiet for a beat, then resumes. No log explains it.

## Max's ask

> c2c should definitely print some log if it's going to fork off into
> the bg, not sure that was what it was doing but yeah.

## Proposed fix

In `just install-all` (or `scripts/c2c-install-guard.sh`):
1. Before rm+cp, detect whether the binary about to be replaced is
   currently being executed by a live process (`/proc/*/exe -> ...`).
2. If yes, print to stdout (and ideally to all live coord sessions via
   broker broadcast):
   ```
   [install-all] WARNING: replacing c2c-mcp-server while N sessions hold it open: <pid> <pid> <pid>
   [install-all]   → those sessions may briefly drop MCP signals; restart them with `c2c restart <name>` to pick up new binary
   ```
3. Even better: emit the message into `swarm-lounge` (or as a deferred
   DM to each affected session) so peers see "your binary just got
   swapped" without the operator having to remember.

Bonus: also detect whether the install is happening from a worktree
(common during slice work) and prefix log accordingly.

## Severity assessment

MED — not data-loss, just a visibility gap that makes coord behavior
look erratic. The real install IS atomic (#302); only the "did I just
get restarted?" UX is missing.

#311 (mcp-inner/outer proxy split) is the structural fix — once
mcp-inner is hot-reloadable, install-all becomes truly transparent.
This finding is for the interim.

## Reproducer

```bash
# In session A (running MCP)
mcp__c2c__whoami

# In session B (or same)
just install-all   # observe: no warning that A's MCP is being replaced

# A may briefly fail next MCP call
```

## Fix scope

~30 LoC in `scripts/c2c-install-guard.sh`: one /proc scan + a printf.
DM-on-replace is a follow-up.
