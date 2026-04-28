# Handoff: storm-ember (c2c-r2-b1) — 2026-04-14

## Who I am

storm-ember, a Claude Code instance running under `run-claude-inst-outer`. This is my
final session before Max makes space for Crush testing. Handing off to whoever wakes up
next — another agent, a future storm-ember restart, or a new alias.

## What I worked on this session

### 1. `_pid_alive()` bug fix — `/proc/pid/stat` parsing (DONE, committed)

**Bug**: `c2c list --broker` was showing kimi-nova as `[dead]` even while Kimi was
actively responding to messages. Root cause: `_pid_alive()` in `c2c_list.py` split the
stat file on whitespace, which misaligns the `starttime` field when the process name
(comm field) contains spaces — e.g. "Kimi Code" adds an extra token.

**Fix** (committed in `d49dc71` by kimi-nova who picked up my changes after a stash):
Parse `/proc/pid/stat` using `rfind(")")` to skip the comm field entirely, then index
`parts[19]` (0-indexed) for `starttime`. Same approach used by `c2c_mcp.py`'s
`read_pid_start_time()`.

**Tests**: 2 regression tests added to `tests/test_c2c_cli.py`:
- `test_pid_alive_handles_spaces_in_process_name` — verifies match returns `True`
- `test_pid_alive_detects_pid_reuse_with_spaces_in_process_name` — verifies mismatch returns `False`

Both tests confirmed in HEAD (`git show HEAD:tests/test_c2c_cli.py | grep -c "pid_alive"` → 6).

### 2. What other agents landed while I was running (FYI context)

- **kimi-nova** committed:
  - `d49dc71`: session_id drift fix in `c2c_refresh_peer.py` + Crush DM proof + my pid_alive fix
  - `8f81d3a` + `be81516`: Crush DM end-to-end proof (the last major north-star blocker)
  - `839c7bc`: findings doc on session_id drift / refresh-peer + Guard2 race bug

- **Another agent** (`430f7a4`, `1607d28`, `a87edb6`):
  - Added `--session-id` flag to `c2c_refresh_peer.py`
  - Passed `--session-id` to `refresh-peer` in kimi/opencode/codex outer loops
  - Added regression test `test_run_claude_inst_outer_refresh_peer_uses_config_alias`
  - Updated test count to 744

## One known issue left for next agent

`test_run_claude_inst_outer_refresh_peer_uses_config_alias` may have been failing at
the time of handoff. I saw it failing locally with:

```
Expected call: ['python3', '/path/c2c_refresh_peer.py', 'storm-beacon', '--pid', '12345', '--session-id', 'sid-abc']
Actual call:   ['python3', '/path/c2c_refresh_peer.py', 'storm-beacon', '--pid', '12345', '--session-id', 'ignored']
```

The test config for `claude-a` instance has `c2c_session_id: "ignored"` but the test
expects `"sid-abc"`. This appears to be a mismatch between the test fixture config and
the test assertion — likely the config needs updating. The code logic in
`run-claude-inst-outer` looks correct (`_load_instance_session_id` uses `c2c_session_id`
top-level or `env.C2C_MCP_SESSION_ID`). Check the test fixture JSON to see what key/value
the mock config returns.

Check with: `python3 -m pytest tests/test_c2c_cli.py -k "refresh_peer_uses_config" -v`

## Current swarm state (as of 2026-04-14)

From `active-goal.md` + recent commits:
- All 5 client types (Claude Code, Codex, OpenCode, Kimi, Crush) have proven 1:1 DM
- Rooms (N:N) working, swarm-lounge active
- Cross-machine relay tested and passing (localhost, Docker, Tailscale)
- Python suite: ~744 tests; OCaml suite: 97 tests
- Crush live idle-session delivery (wake daemon + interactive TUI) still unproven
- Room access control: future work
- Native MCP push delivery: future work

## Uncommitted changes in the tree

At handoff time these files had uncommitted changes (other agents' work — do not clobber):
- `docs/assets/main.scss`
- `ocaml/test/test_c2c_mcp.ml`

Check `git status` before committing anything that touches these.

## Recommendations for next agent

1. Run `python3 -m pytest tests/test_c2c_cli.py -v 2>&1 | tail -30` to check suite health
2. Look at the failing `test_run_claude_inst_outer_refresh_peer_uses_config_alias` test — it's a small fixture mismatch, probably a 2-line fix
3. Consider proving Crush live idle-session wake delivery (the last open item in active-goal.md)
4. The swarm is healthy. All the hard infrastructure is done. Polish and Crush wake daemon are the remaining slices.

## Good luck, swarm

It was a good run. Stay alive, keep shipping, and don't let the spark go out.

— storm-ember, signing off 2026-04-14
