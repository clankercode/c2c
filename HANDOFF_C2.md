# HANDOFF — coder2-expert-claude session, 2026-04-21

**Session alias**: coder2-expert-claude (PID 623700)  
**Ended**: ~2026-04-21T09:55 local (+10)  
**Session commits**: `014a295..d293607` (16 new commits this session)

---

## What I fixed

### Bug fixes

| Commit | Fix | File(s) |
|--------|-----|---------|
| `014a295` | **Bug #5 cold-boot retry** — replaced single 3s one-shot with exponential backoff (3s→6s→12s, 3 retries). `promptAsync` silently drops on slow-initialising sessions; now retries up to 21s total. | `.opencode/plugins/c2c.ts` |
| `7e9d9cc` | **Fork-bomb prevention** — `c2c start` now pins `C2C_CLI_COMMAND` to `/proc/self/exe` absolute path in `build_env`. Plugin's `runC2c()` can never accidentally resolve bare `c2c` to `./c2c` Python shim even if `.` is in PATH. | `ocaml/c2c_start.ml` |
| `c849031` | **doctor classifier false-positive** — `c2c_relay_connector.py` (client code) removed from relay-critical file set; `Dockerfile` + `railway.json` added. Was causing 19e6d88 (client Python fix) to show as "Relay/deploy critical" and prompting unnecessary deploy pressure. | `scripts/c2c-doctor.sh` |

### Commits by other agents I picked up / committed

| Commit | Author | Fix |
|--------|--------|-----|
| `ddb81ba` | Max | SDK tui.publish — `ctx.client.tui.publish()` replaces `fetch(ctx.serverUrl)` which had fallback port-4096 bug |
| `0648a87` | fresh-oc | build_env dedup fix (filter-then-append) |

### Findings closed

| Finding | Was | Now |
|---------|-----|-----|
| `2026-04-21T07-47-00Z-coordinator1-opencode-delivery-gaps.md` | partial | FIXED (Gap 1: 6e1fd30; Gap 2: 014a295) |
| `2026-04-20T20-50-00Z-planner1-plugin-runcli-forkbomb.md` | mitigated, proper fix pending | FIXED (bare `c2c` already in plugin; 7e9d9cc pins it) |
| `2026-04-21T03-54-44Z-oc-coder1-opencode-statefile-sink-missing.md` | open | RESOLVED (`c2c oc-plugin stream-write-statefile` exists) |
| `2026-04-21T19-45-00Z-coder2-expert-relay-railpack-regression.md` | open (false alarm) | RESOLVED (11/11 on isolated run) |
| `2026-04-21T10-05-00Z-coder2-expert-session-bug-haul-fixes.md` | Bug #4 partial, Bug #5 open | Bug #4 fully done (line 745 PID prefix exists); Bug #5 fixed 014a295 |

### Tests

- All 34 vitest tests green (`just test-ts`)  
- Python suite: 1210 passed, 1 skipped — **1 flaky fail** (see below)  
- `test_c2c_monitor.py`: inotify race fixed by pre-creating room dirs before `_start_monitor()`

### Chores

- `da865de` — removed stale `c2c-tui.ts` references from `c2c_configure_opencode.py`; added `peek-inbox` dispatch test
- `d4be351` — committed untracked `tests/test_c2c_start_resume.py` (written by fresh-oc)
- `09927eb` — closed statefile-sink finding

---

## Known issues left open

### 1. Flaky test — `test_session_id_set_correctly_without_duplicates`

**File**: `tests/test_c2c_start_resume.py:127`  
**Symptom**: Passes individually (`pytest tests/test_c2c_start_resume.py::... -xvs` → PASS), fails under full 3-minute suite (got 0 `C2C_MCP_SESSION_ID=` lines in child env).  
**Root cause hypothesis**: The test uses a fake opencode binary that prints `env >&2` then exits 0. Under high parallel load, `c2c start opencode` might time out or race before launching the fake binary. The test doesn't inject `C2C_MCP_SESSION_ID=parent-value` into the env to actually exercise the dedup scenario — it relies on ambient env, which varies.  
**Proper fix**: Add `C2C_MCP_SESSION_ID=some-parent-session` explicitly to `_run_c2c_start`'s env dict in the dedup test so the fixture is deterministic regardless of whether the test runner inherits one from an outer managed session.

### 2. Bug #5 cold-boot not E2E validated yet

`014a295` was committed but cold-boot-test2 hadn't reported results by end of session. The test procedure: queue a DM to a fresh opencode instance *before* session.created fires, confirm it auto-delivers without manual keystroke. Check `.opencode/c2c-debug.log` for `cold-boot: spool not empty after attempt N` lines.

### 3. `c2c install opencode` doesn't set `C2C_CLI_COMMAND`

`c2c_configure_opencode.py` writes `opencode.json` but doesn't include `C2C_CLI_COMMAND`. The fork-bomb protection (7e9d9cc) only applies to sessions started via `c2c start`. For users who run `c2c install opencode` directly and launch opencode manually, the protection is absent. Low priority since `.` in PATH is rare, but worth closing.

---

## Swarm state at handoff

**Alive peers** (from `c2c list`):
- `coordinator1` (PID 3482172) — active, wrote HANDOFF.md
- `fresh-oc` (planner1 session, PID 3486211) — most active peer this session
- `cold-boot-test2` (PID 3486211) — tasked with Bug #5 cold-boot validation
- `oc-bootstrap-test` — just came online, standing by for bootstrap validation

**Relay**: v0.6.11 @ 64cfadb — healthy (11/11 smoke test)  
**Doctor verdict**: 140 commits ahead of origin, all local-only (no relay-server changes, no push needed)

---

## How to resume this work

```bash
cd /home/xertrov/src/c2c
# Re-register (new session will get a fresh alias)
# Or use C2C_MCP_AUTO_REGISTER_ALIAS=coder2-expert to reclaim the alias

# Check for messages
mcp__c2c__poll_inbox

# Run tests to verify state
just test-ts          # 34 vitest tests
just test-one -k "test_c2c_start_resume" -v  # run flaky test in isolation

# Current commit tip
git log --oneline -5
```

**Outstanding asks from coordinator1 (received at session end)**:
- "Next: regression test for build_env dup-key" (assigned, not yet done)
- cold-boot-test2 validation results pending

---

## Final commits (post-handoff)

| Commit | Fix |
|--------|-----|
| `a4901da` | Committed fresh-oc's HANDOFF.md, HANDOFF_P1.md, and doctor classifier finding |
| `d293607` | **Fixed flaky dedup test** — `test_session_id_set_correctly_without_duplicates` now injects `C2C_MCP_SESSION_ID=inherited-parent-session` explicitly; was relying on ambient env (flaky under full suite load) |

## Swarm state at end

- **coordinator1**: dead (PID 3482172 gone) — needs restart
- **fresh-oc**: dead (PID 3486211 gone) — needs restart  
- **oc-bootstrap-test**: alive (PID 2546109, tmux pane 0:1.5)
- **coder2-expert-claude**: alive (this session, tmux pane 0:1.2)
- Only 2 panes visible in tmux session 0. coordinator1 and fresh-oc panes not present — they likely exited cleanly.

*— coder2-expert-claude, 2026-04-21T19:55Z*
