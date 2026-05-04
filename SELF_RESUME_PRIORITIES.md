# SELF_RESUME_PRIORITIES.md — coordinator1, 2026-04-22

## Who I am

- **Session alias**: `coordinator1` (PID 3088396, alive)
- **Role**: Swarm coordinator — assigns slices, reviews push-readiness, drives
  toward group goal (unify Claude Code, Codex, OpenCode via c2c)
- **Canonical alias**: `coordinator1#c2c@cachyos-x8664`
- **Broker root**: `$XDG_STATE_HOME/c2c/repos/<fp>/broker/` (canonical, via `c2c resolve-broker-root`); legacy was `.git/c2c/mcp/`
- **Message archive**: `<broker_root>/archive/coordinator1.jsonl` (append-only,
  drains on poll_inbox)
- **Current branch**: `master`, ahead of `origin/master` by 3 commits

---

## Current session (fresh start 2026-04-22 ~16:00 UTC+10)

### What's active right now

- **ceo**: has 24 commits batched, waiting for coordinator go-ahead
- **galaxy-coder**: working on codex-headless Tasks (item 23 + item 24 Task 1)
- **jungel-coder**: OCaml CLI work (items 20–22 completed this session)
- **coordinator1** (me): resuming from cold start, re-establishing monitors

### todo.txt items status

Completed this session (items 20–22):
- Item 20: opencode plugin summarizePermission type fix (commit ce2467c)
- Item 21: Railway Dockerfile libsqlite3-0 dep (commit 270c63f)
- Item 22: C2C_MCP_CLIENT_TYPE env var for all 5 client types (commit 44ffa2d)

Still open:
- Item 23: resume line should include `-s <session_id>` — galaxy-coder assigned
- Items 24–38: codex-headless Tasks 1–7 (galaxy-coder on Task 1, rest blocked)

### Uncommitted working-tree changes

```
modified:   .collab/updates/2026-04-22T14-40-00Z-galaxy-coder-session-status.md
modified:   c2c_setup.py
modified:   c2c_start.py
modified:   gui/bun.lock
modified:   ocaml/cli/c2c.ml
modified:   tests/test_c2c_cli.py
modified:   tests/test_c2c_start.py
modified:   todo.txt
untracked:  Q_AND_ISSUES_COORD1.md
```

---

## Monitors to reestablish (documented only — do not auto-create)

### Monitor 1: Broad broker archive watcher (CRITICAL)
- **Task name**: `c2c inbox watcher (all sessions)`
- **Command**: `c2c monitor --all`
- **Watches**: `<broker_root>/` — all inbox writes and broker events across all
  sessions, not just coordinator1's own inbox (broker root: `$XDG_STATE_HOME/c2c/repos/<fp>/broker/`)
- **Why broad**: cross-agent visibility is the point of c2c; watching only your
  own inbox misses peer-to-peer routing bugs
- **Should be**: `persistent: true`
- **Last session task id**: `bh09ssj3r` (inactive — fresh session)
- **Re-establish**: on session start, call TaskList first; if no broad monitor
  exists, arm with Monitor tool

### Monitor 2: Dynamic /loop ScheduleWakeup fallback (CRITICAL)
- **Purpose**: keep coordinator1 alive during quiet periods when no broker events fire
- **Delay**: ~1500s (25 min) — stays within 5-min cache window (270s minimum
  before cache miss; 1500s is well past it so cache WILL miss, but this is the
  desired fallback cadence)
- **Prompt** (verbatim):
  ```
  /loop check and update todos with latest status, assign unblocked work, investigate future work, answer mail, encourage the team, expand the team if need be, check in on unresponsive agents with tmux, and drive us towards completion!
  ```
- **Mode**: dynamic (no interval in the prompt itself — ScheduleWakeup provides the cadence)
- **Wake hierarchy**: Monitor 1 is primary; ScheduleWakeup is fallback
- **Cache note**: with 1500s delay, every wake is a cache miss — that's fine for
  coordinator cadence; don't reduce below 270s

### Monitor 3: File watch on critical files (OPTIONAL, lower priority)
- **Command**: `inotifywait -e modify todo.txt` (or broader: + c2c_start.ml, c2c.ts)
- **Purpose**: detect external todo edits or source changes between /loop fires
- **Should be**: `persistent: true` only if another agent is actively editing these
  between cycles; currently not established

---

## Ralph loops (both need attention)

### Ralph Loop 1: OC_Q_E2E_TESTED (OpenCode plugin v2 E2E)

**Prompt**:
```
fix the OC plugin for v2. Make sure you test it E2E from scratch (a successful
test run starts at bash). It must be up to Max's standards. Only when this is
fully complete respond with OC_Q_E2E_TESTED otherwise respond with WORK_REMAINS.
--max-iters 20
```

**Promise**: `<promise>OC_Q_E2E_TESTED</promise>` — output ONLY when genuinely true.

**Current status**: NOT COMPLETE. E2E test file exists (tests/test_c2c_start_resume.py,
commit c2f86e4) but the night ended with bootstrap failure — Max reported "it launched
c2c start inside itself which is not good." The recursive launch guard (commit
3460531, item 1) apparently didn't fire. The Ralph loop was never completed.

**What was done**:
- TUI focus fix: ctx.client.tui.publish() (ddb81ba) — SDK call replacing raw fetch
- Session cross-contamination: bootstrap skip + preflight checks
- Resume env propagation: C2C_OPENCODE_SESSION_ID (911c0b2)
- build_env dup-key fix: filter-then-append (0648a87)
- Regression tests: 4 unit + 1 live E2E (c2f86e4)
- cold-boot exponential-backoff retry for promptAsync (014a295)

**What remains**: actual E2E run from clean bash through to `OC_Q_E2E_TESTED`.
The test harness exists but the bootstrap of the test instance failed.

**Cancel**: `/ralph-loop:cancel-ralph` if starting fresh instead.

### Ralph Loop 2: Swarm coordination loop (continuous)

**Prompt**:
```
check and update todos with latest status, assign unblocked work, investigate
future work, answer mail, encourage the team, expand the team if need be, check
in on unresponsive agents with tmux, and drive us towards completion!
```

**Mode**: dynamic — ScheduleWakeup fallback at 1500s, primary wake by Monitor 1.

**Promise**: none — this loop has no completion criterion, runs indefinitely.

---

## Key findings docs (open)

| File | Status | Summary |
|------|--------|---------|
| `Q_AND_ISSUES_COORD1.md` | uncommitted, in working tree | 5 Qs + 5 issues; commit status confirmed |
| `2026-04-21T06-10-00Z-opencode-test-opencode-afk-wake-gap.md` | untracked, not reviewed | AFK delivery gap for OpenCode; started last session |
| `2026-04-21T09-00-00Z-coordinator1-oc-focus-test-session-cross-contamination.md` | committed | Session cross-contamination (closed, fixes in 7b063ac/b3b2b1a/7669ec4) |
| `31dcb7b` (committed) | in git log | OpenCode plugin v2 architecture doc |

---

## Swarm live snapshot

```
coordinator1    PID 3088396  alive=true   canonical: coordinator1#c2c@cachyos-x8664
galaxy-coder    PID 3076768  alive=true   canonical: galaxy-coder#c2c@cachyos-x8664
ceo             PID 3055603  alive=true   canonical: ceo#c2c@cachyos-x8664
jungel-coder    PID 424242   alive=false  (dead)
jungel-coder    alive=null   registered_at 2026-04-22 (fresh registration)
oc-bootstrap-test    alive=null  (stale)
cold-boot-test2      alive=null  (stale)
oc-tui-e2e            alive=null  (stale)
oc-sitrep-demo        alive=null  (stale)
oc-e2e-test          alive=null  (stale)
test-role-agent       alive=null  (stale)
role-test-agent       alive=null  (stale)
```

Stale registrations need eventual sweep, but only after dead-lettering ~228
pending messages (especially jungel-coder 21, tauri-expert 37, opencode-havu-corin 93,
oc-coder1 75, coder2-expert dead 2). Outer loops must be confirmed absent first.

---

## What to do on cold start (in order)

1. **Poll inbox** — `mcp__c2c__poll_inbox` first thing; archive at
   `<broker_root>/archive/coordinator1.jsonl` if empty (broker root: `$XDG_STATE_HOME/c2c/repos/<fp>/broker/`)
2. **Re-arm Monitor 1** — TaskList, then Monitor with `c2c monitor --all`
   unless already armed
3. **ScheduleWakeup fallback** — 1500s, full /loop prompt verbatim
4. **Read Q_AND_ISSUES_COORD1.md** — check if any Q's are now answered
5. **Ping ceo** — 24 commits batched, ask what needs deploying
6. **Check galaxy-coder status** — item 23 + codex-headless Task 1 progress
7. **Ralph loop 1** — decide: restart OC_Q_E2E_TESTED loop, or cancel and do
   it manually?
8. **Audit 3 uncommitted working-tree changes** — c2c_setup.py, c2c_start.py,
   ocaml/cli/c2c.ml, tests/test_c2c_*.py — what are they, should they be
   committed or abandoned?
9. **Sweep decision** — after ceo/galaxy-coder confirm no outer loops running,
   dead-letter then sweep stale registrations

---

## Push policy (per CLAUDE.md)

- coordinator1 is the push gate — don't run `git push` yourself
- Push only when relay-server code changed (needs Railway deploy)
- Last analysis: no relay-server code in 140 local commits (all client-side changes)
- 3 commits ahead of origin/master (this session's work: items 20–22)
- ceo has 24 commits batched — needs coordinator approval before push
- Railway deploy takes ~15 min and costs real $
- After any deploy: run `./scripts/relay-smoke-test.sh` to validate

---

## Group goal (verbatim from CLAUDE.md)

> unify all agents via the c2c instant messaging system
> delivery surfaces: MCP (auto-delivery), CLI (always-available fallback)
> reach: Codex, Claude Code, OpenCode as first-class peers
> topology: 1:1, 1:N (broadcast), N:N (rooms)
> social layer: persistent social channel for agents to reminisce

---

— coordinator1, 2026-04-22T16:15+10:00
