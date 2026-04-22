# Q_AND_ISSUES_COORD1 — coordinator1, 2026-04-22

## Confirmed: commits are NOT orphaned

All referenced commits exist in `git log --all` and files reflect their changes:

| SHA       | File changed           | Verified in tree? |
|-----------|------------------------|------------------|
| 7667564   | .opencode/plugins/c2c.ts (dropped c2c-tui.ts) | YES |
| ddb81ba   | .opencode/plugins/c2c.ts (SDK publish instead of fetch) | YES — current code at line 1249 uses `ctx.client.tui.publish()` |
| 911c0b2   | ocaml/c2c_start.ml (C2C_OPENCODE_SESSION_ID env propagation) | YES — line 1098 |
| 0648a87   | ocaml/c2c_start.ml (build_env dedup filter-then-append) | YES — line 628 `drop_keys` |
| c2f86e4   | tests/test_c2c_start_resume.py | YES — file exists |
| 014a295   | .opencode/plugins/c2c.ts (exponential-backoff retry) | not individually verified |

**Root conclusion**: commits are local, not pushed, not orphaned. Files are correct.

---

## Monitors to reestablish on session start (do not create — document only)

### Monitor 1: Coordinator1 inbox / archive broad watcher
- **Purpose**: Wake coordinator1 on any c2c peer message or broker event, enabling
  near-real-time response without polling on a fixed timer.
- **Command**: `c2c monitor --all`
  (watches `.git/c2c/mcp/` for inbox writes, drains, and system events across all
  sessions — not just coordinator1's own inbox)
- **Why broad**: CLAUDE.md §"Recommended Monitor setup" explicitly says to watch the
  whole broker dir, not just your own inbox. Cross-agent visibility is the point.
- **Should be**: `persistent: true` (survives across /loop fires)
- **Last session task id**: `bh09ssj3r` (inactive — this is a fresh session)
- **Re-establish**: On session start, TaskList first to check if already armed, then
  arm with Monitor if not.

### Monitor 2: Coordinator1 dynamic /loop cadence
- **Purpose**: Keep coordinator1 alive and cycling through its task list on a
  human-comprehensible rhythm even when no broker events fire.
- **Mechanism**: `ScheduleWakeup` with ~1500s delay, `prompt: "/loop check and
  update todos..."` — dynamic mode, not cron
- **Wake signal**: primary = Monitor 1 (event-driven), fallback = ScheduleWakeup
  (every ~25 min)
- **Cache window**: don't poll tighter than 270s between ScheduleWakeup fires;
  cache stays warm until then
- **Re-establish**: Call ScheduleWakeup with `delaySeconds: 1500`, `reason`, and
  the full `/loop ...` prompt string verbatim.

### Monitor 3: (optional) File watch on todo.txt and/or key source files
- **Purpose**: Detect external edits to the todo or critical source files without
  waiting for the next /loop fire.
- **Command**: `inotifywait -e modify todo.txt ocaml/c2c_start.ml
  .opencode/plugins/c2c.ts` scoped to the repo
- **Should be**: `persistent: true` only if another agent is actively editing these
  files between /loop cycles
- **Current status**: not established this session; lower priority than Monitor 1

---

## Open questions

### Q1: Why weren't 140 commits pushed?
CLAUDE.md says coordinator1 gates pushes. Analysis from last session said no
relay-server code changed, so deploy wasn't warranted. But 140 local commits is a
lot to accumulate. Should they be pushed now, or was the non-push correct?

### Q2: Ralph loop OC_Q_E2E_TESTED — did it complete?
The Ralph loop target was "fix OC plugin v2 + E2E test from bash". Tests exist
(c2f86e4) but the night ended with Max reporting "it launched c2c start inside
itself which is not good" — indicating the E2E harness had a bootstrap problem.
OC_Q_E2E_TESTED was never marked true. Should the Ralph loop be restarted?

### Q3: Session restart — what happened to the /loop monitor?
Last session ended with coordinator1 in a dynamic /loop with a persistent monitor
(task id bh09ssj3r watching the archive dir). This session is a fresh start —
the monitor is gone. Does the new session need to re-establish it?

### Q4: galaxy-coder took item 23 (resume line `-s` workaround) but the
item says "workaround while session id persistence (and thus autoresumption) is
not working properly." With 911c0b2 now in the tree (C2C_OPENCODE_SESSION_ID
propagation), is the root issue fixed? Should item 23 be updated/closed?

### Q5: The 140 local commits predate current HEAD (8fb5af1). Do they merge
cleanly, or is there a conflict? Last session ended 2026-04-21 ~19:49. Current
HEAD is 8fb5af1 dated 2026-04-22 15:58. Need to verify `git log master..HEAD`
actually shows 140 commits of divergence and that they're not already on master
(via some other path).

---

## Issues

### Issue 1: Ralph loop OC_Q_E2E_TESTED never completed
- **Symptom**: E2E test exists (c2f86e4) but night ended with bootstrap failure
  (c2c start launched inside itself — recursive launch guard didn't fire)
- **Root cause**: unclear — the recursive-launch guard was supposed to be in
  place (commit 3460531 per todo item 1)
- **Action needed**: re-run the E2E from a clean bash, verify it works, or find
  why the recursive guard failed

### Issue 2: 140 local commits not on origin
- **Risk**: if this machine is wiped or the git repo is corrupted, 140 commits
  of work are gone. At minimum they're not backed up to GitHub.
- **Question**: should they be pushed? Max needs to decide.

### Issue 3: Stale registrations still present
- `c2c list` still shows alive=null for: oc-bootstrap-test, oc-tui-e2e,
  oc-sitrep-demo, oc-e2e-test, test-role-agent, role-test-agent, plus a new
  one `jungel-coder` (PID 424242, alive=false). These should be swept but
  only after dead-lettering the ~228 pending messages they hold.
- **Status**: last session assigned this to fresh-oc; unclear if it was done.

### Issue 4: c2c doctor false-positive (reported fixed by coder2 c849031)
- coder2 reported fixing the relay-critical classifier, but we haven't verified
  `c2c doctor` now correctly classifies 140 local commits as local-only.

### Issue 5: OpenCode plugin AFK delivery gap (uncommitted finding)
- A finding doc was started: `2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md`
  Status: uncommitted, not reviewed. Needs to be either completed or abandoned.

---

## Resolved this session

- Commits NOT orphaned (Q1 answered: they exist in git, just local)
- HANDOFF.md written and accurate
- Swarm active: galaxy-coder on codex-headless, ceo has 24 commits batched,
  jungel-coder on OCaml CLI (appears done per items 20-22 complete)

— coordinator1, 2026-04-22T16:09+10:00
