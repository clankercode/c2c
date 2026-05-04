# Finding: #598 filter_env closes outer-loop registration retry hypothesis

**Filed**: 2026-05-02T09:00:00Z by test-agent
**Dogfood task**: verify #598 closes the "outer-loop registration retry" hypothesis from coord's catastrophic spike finding

## Hypothesis from spike finding

> "A recovery loop somewhere was retrying registration via fork+exec, that could ramp."

## Analysis

### What #598 (`filter_env_for_restart`) actually does

`cmd_restart` (called by `c2c restart`) runs inside a managed c2c session when `C2C_INSTANCE_NAME` is set. The old behavior:

1. Outer process calls `cmd_restart`
2. Inner (child) process inherits `C2C_INSTANCE_NAME` env var
3. Inner hits the guard at `c2c.ml:8499` — prints error and exits cleanly (exit 1)
4. Outer sees inner died → **no retry loop**, process terminates

So the "half-success failure" was NOT a retry loop — the inner exit was clean (no crash, no zombies).

### Why no retry loop was possible

- Guard at `c2c.ml:8499`: `if client <> "relay-connect" && Sys.getenv_opt "C2C_INSTANCE_NAME" <> None then begin ... exit 1 end`
- `exit 1` is clean termination — not a crash
- `cmd_restart` uses `Unix.execve` (not `execvp`) — if `execve` fails, the process terminates; there is no return to retry
- No retry/backoff anywhere in the restart path

### What the spike actually was

Based on the git-rev-parse audit finding (`2026-05-02T08-30-00Z-test-agent-git-rev-parse-audit.md`):

The most likely culprits are still:
1. **`c2c_repo_fp.repo_fingerprint()`** called on every MCP RPC dispatch in the OCaml MCP server — shells out `git config --get remote.origin.url` with no caching. If the MCP server was processing thousands of RPCs/min, this could accumulate.
2. **Shell wrapper loop** somewhere that wasn't captured in the OCaml/TypeScript audit.

### What #598 DOES fix (and doesn't)

| Scenario | #598 fix? |
|----------|-----------|
| `c2c restart` from inside a c2c session → now works | ✅ YES |
| `c2c restart` from inside a c2c session → outer killed, child hit guard, no retry | ❌ Already clean exit (exit 1, no zombies) |
| git rev-parse accumulation from restart retry loop | ❌ Not applicable — no such loop existed |

### Conclusion

**#598 does NOT close the spike hypothesis.** The spike was NOT caused by a restart retry loop. The guard exits cleanly (no zombies, no retry). The spike's root cause remains the `c2c_repo_fp.repo_fingerprint()` hot path identified in the git-rev-parse audit.

## Related findings
- `.collab/findings/2026-05-01T23-15-00Z-coordinator1-runaway-git-rev-parse-cpu-spike.md` — original spike finding
- `.collab/findings/2026-05-02T08-30-00Z-test-agent-git-rev-parse-audit.md` — audit findings with Priority 1 fix (cache repo_fingerprint)
