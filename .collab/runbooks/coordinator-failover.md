# Coordinator Failover Protocol

**Status:** Active operational protocol as of 2026-04-26
**Audience:** designated recovery agent + all swarm peers
**Cadence:** runbook — read on session start if you are the recovery agent or backup

---

## TL;DR

If coordinator1 goes offline, **lyra-quill** assumes coord role until
primary returns. Detection is by: hourly liveness check (lyra), no sitrep
at `:07`, peer DM sits unread >15min, or coord tmux pane shows shell
prompt. Takeover steps are in §4. Handback in §5.

---

## 1. Roles & Succession

**Primary coordinator:** `coordinator1` (Cairn-Vigil).

**Designated recovery agent (current):** `lyra-quill`.

**Succession order if primary AND lyra both unavailable:**
1. lyra-quill
2. jungle-coder
3. stanza-coder
4. Max ad-hoc

The designated recovery agent should re-read this doc at session start
and at every `coord liveness check` heartbeat tick.

---

## 2. Why this matters

The swarm has a single coordinator who gates: routing, cherry-picks,
peer-PASS → coord-PASS, push timing, sitreps. If coord stalls, the
swarm stalls — peers DM and get nothing.

The recovery agent's job is to **detect**, **diagnose**, **take over
without making things worse**, and **hand back cleanly**.

---

## 3. Detection — when to act

Any of these indicate coord is down or stuck:

- **No sitrep at `:07`** for the current hour and no DM explanation.
- **Peer DMs to coordinator1 sit unread >15min** during active
  session hours. Verify by peeking coord's pane.
- **Coord tmux pane shows shell prompt** (claude/codex exited).
- **`c2c stats --alias coordinator1 --json`** shows compacting% near
  100% for >10min, OR last_activity_ts >30min ago.
- **Coord registered with a dead pid** (`kill -0` fails on the registry
  pid).

**Do NOT act on transient slowness** (single missed sitrep, brief
compacting period). Wait one full cycle before assuming failure.

The recovery agent should arm a standing heartbeat at session start
to remind themselves to check:

```
heartbeat 1h+13m "coord liveness check — peek coordinator1 pane, verify alive"
```

---

## 4. Takeover sequence

Run these in order **only after detection criteria are met**.

### 4.1 Diagnose first (don't take over speculatively)

```bash
# Find coord's pane
./scripts/c2c_tmux.py list

# See current pane state
./scripts/c2c_tmux.py peek coordinator1

# Optional: full transcript dump
./scripts/c2c_tmux.py capture coordinator1 > /tmp/coord-state-$(date +%s).txt

# Health snapshot
c2c stats --alias coordinator1 --json
c2c list | grep coordinator1
```

Match the symptom against §6 "Common failure modes" before taking
over. If it's a known recoverable failure (compacting, blocked
permission prompt), wake the coord rather than replacing.

### 4.2 If recoverable: wake the coord

- **Compacting >5min:** wait, then nudge with `c2c send coordinator1
  "<heartbeat>"`. Compacting can take 10+ min on a long context.
- **Blocked on permission prompt:** approve via tmux:
  ```bash
  ./scripts/c2c_tmux.py keys coordinator1 1   # option 1: yes
  ./scripts/c2c_tmux.py keys coordinator1 Enter
  ```
- **Stuck/idle but alive:** ping with cache-keepalive equivalent.
  Last resort: `Ctrl-c` via `keys coordinator1 C-c` to break a
  hung tool call.

If wake succeeds, post a 1-line note in `swarm-lounge` and stay on
peer-review-only mode. Do NOT take over coord responsibilities.

### 4.3 If unrecoverable: take over

1. **Announce in `swarm-lounge`:**
   > "lyra-quill assuming coord role per failover protocol.
   > Reason: \<one-line symptom\>. Coord pane state captured at
   > /tmp/coord-state-\<ts\>.txt. Will hand back when coordinator1
   > returns."

2. **Adopt coord responsibilities:**
   - Set `C2C_COORDINATOR=1` in your shell environment when running
     `git commit` to bypass the pre-commit hook (the bypass should
     also be in your role frontmatter — see §7 ⚠️).
   - Receive peer-PASS DMs and cherry-pick to master.
   - Run `c2c coord-cherry-pick <SHA>` for the cherry-pick + build
     pipeline (auto-stash + restore + just install-all).
   - Drive sitreps at `:07`.
   - Use `mcp__c2c__send_room swarm-lounge` for fan-out
     announcements.

3. **DO NOT push to origin/master.** Holding is the default.
   Pushing while coord is recovering compounds reconciliation.
   Exception: relay-critical hotfix unblocking the whole swarm —
   announce in `swarm-lounge` first.

4. **Open a recovery log** at
   `.c2c/personal-logs/lyra-quill/coord-takeover-<UTC>.md`. Append
   each significant action: detection signals, takeover time,
   cherry-picks landed, decisions made, anything novel.

### 4.4 If recovery agent is also unavailable

Succession (jungle, stanza, Max) is informal — whoever sees the gap
first announces takeover in `swarm-lounge` per §4.3. The recovery
log captures it. Max resolves any contention.

---

## 5. Handback

When primary coord returns:

1. **Primary announces:** "coordinator1 back online, resuming coord
   role from \<recovery-agent\>." in `swarm-lounge`.
2. **Recovery agent confirms:** posts the recovery log path, lists
   what was done, what's pending. Reverts to peer-review mode.
3. **Primary reviews** the recovery log + any cherry-picks landed
   during takeover. Updates docs / files findings if novel patterns
   emerged.
4. **No retroactive coord-PASS** — work landed by recovery agent
   stays as-is unless primary explicitly objects.

---

## 6. Common failure modes (to-be-grown)

| Symptom | Diagnose | Action |
|---|---|---|
| Coord at compacting >5min | `peek` shows compaction UI | Wait. Send heartbeat at 5m mark. |
| Coord at shell prompt | `peek` shows `$` | Claude/Codex exited. Run `./restart-self` via tmux keys. |
| Permission prompt blocking | `peek` shows "Would you like to run..." | Send option key + Enter via `c2c_tmux.py keys`. |
| Stuck mid-tool-call | last_activity_ts old, pane has spinner | `Ctrl-c` then heartbeat. Last resort: kill + restart. |
| Dead pid in registry | `kill -0 $pid` fails | `c2c refresh-peer coordinator1 --pid <new>` if alive elsewhere; else takeover. |
| Quota exhaust | tmux footer shows 0% remaining (Claude) or 100% used (Codex inverted) | Wait for reset window. Coord can't act. |

Append new rows here as they're encountered.

---

## 7. Required tooling & state

- ✅ `scripts/c2c_tmux.py` — peek/capture/keys for diagnosing.
- ✅ `c2c stats --alias <alias> --json` — health snapshot (S2+S3+S4 shipped).
- ✅ `c2c coord-cherry-pick <SHA>` — auto-stash + cherry-pick + build (test-agent OCaml port shipped).
- ✅ `mcp__c2c__peek_inbox` — see what's queued for coord.
- ✅ Pre-push hook installed — origin/master pushes blocked unless `C2C_COORDINATOR=1`.
- ⚠️ **`C2C_COORDINATOR=1` bypass for recovery agent**: lyra's
  role frontmatter SHOULD have this conditionally enabled with a
  "I am the active coord" toggle. **Currently NOT configured.**
  Implementation TBD: add per-agent bypass flag in
  `.c2c/roles/<alias>.md` honored by pre-commit hook. Until then:
  recovery agent must export `C2C_COORDINATOR=1` manually for any
  master commit, ONLY during active takeover.

---

## 8. Process improvements pending

- [ ] Wire `C2C_COORDINATOR=1` conditional bypass into recovery
      agent's role frontmatter so they don't have to manually export.
- [ ] Standing `heartbeat 1h+13m "coord liveness check"` armed in
      lyra's session by default at install time.
- [ ] Add `c2c failover-status` doctor check that reports last
      sitrep time, coord last_activity_ts, and recovery agent
      reachability.

---

## 6. Real-world failover — 2026-04-29 (stanza surge, ~5.5h)

The first observed end-to-end coord-failover happened 2026-04-29
~03:35 → ~09:13 UTC. coordinator1's tmux pane was destroyed; pid
3216984 left the process list. Lyra-quill was registered-but-null
(designated recovery agent unavailable). Jungle was alive but
heads-down on a #379 review loop and explicitly asked stanza to
surge. Stanza took the gate for ~5.5h, landed 9 cherry-picks under
coord rules, then handed back cleanly when coord1 respawned.

Recording the actual sequence so the next failover doesn't have to
re-derive from first principles. Pairs with two findings filed
during the surge: `2026-04-29T04-20-00Z-stanza-coder-surge-coord-premature-cherry-pick.md`
(the rule that became #427 Pattern 9) and
`2026-04-28T22-44-00Z-stanza-coder-cwd-drift-and-stash-in-worktree.md`
(the worktree-discipline pattern that hits coords + subagents the
same way).

### 6.1 What worked

- **Detection from peer broadcast, not poll loop.** Stanza's
  attempted `mcp__c2c__send` to coordinator1 returned `recipient
  is not alive` on the first attempt. That was the
  single-message-fail-rule signal — the runbook §3 detection
  table says "DM bounce on a normal coord-traffic message" is a
  high-confidence signal. Faster than waiting on a missed sitrep
  at `:07`.

- **`ps -p <pid>` to confirm pane death.** `c2c list` showed
  `alive: false` but the runbook recommends ALSO checking the OS
  side. `ps -o pid,etime,cmd -p <pid>` returning empty confirms
  the kernel-side process is gone, not just unresponsive. This
  ruled out compact-loop / harness-stall — coord was truly out.

- **`./scripts/c2c_tmux.py peek coordinator1` BEFORE taking
  over.** Per §4.1 — peek surfaced "alias not live in any pane —
  using last-known target" with stale slate-coder content. That's
  the canonical pane-death pattern; SIGUSR1 / heartbeat-nudge
  recovery was off the table.

- **Lounge broadcast before acting.** Stanza posted in
  swarm-lounge announcing the surge ("temporarily per failover
  succession lyra null, jungle silent ~5min") rather than DMing
  Max ad-hoc. Two minutes later jungle confirmed she was busy on
  the #379 loop and stanza should keep the gate. The lounge
  broadcast ALSO caught test-agent and birch-coder, who then
  routed peer-PASS-ready SHAs to stanza directly — the social
  signal cascaded the queue toward the surge agent.

- **Strict artifact-before-cherry-pick after the
  premature-cherry-pick incident.** Stanza cherry-picked 8 of
  birch's #407 S5 chain on cedar's signed peer-PASS artifact
  alone before realizing cedar was a co-author and birch was
  awaiting slate's fresh-eye PASS. The 9th commit conflicted on
  Dockerfile, surfacing the issue mid-batch. Recovery: `git
  reset --hard fbf5bd62` to drop the 8 transient commits, then
  hold until slate's fresh-eye PASS. Filed as the finding that
  became #427 Pattern 9 (co-author PASS vs cherry-pick gate).
  After Pattern 9 landed, every subsequent cherry-pick required
  the formal artifact PLUS the slice author's "ready" signal.
  Jungle was asked to sign artifacts for #379 S3 even though
  she'd DM'd PASS — the artifact is the gate.

- **Multi-commit chains via `coord-cherry-pick --no-dm`.** For
  #407 S5's 10-commit chain, `--no-dm` skipped per-commit
  notifications (which would have flooded birch's inbox); stanza
  DM'd birch once at the end with the full landing summary.
  Pattern: use `--no-dm` for multi-commit chains, regular auto-DM
  for single commits.

- **Honest perf reality-check in commit body.** Stanza's #420
  audit projected ~1s wall-clock saving from compile-time SHA
  embed. The actual measurement under warm cache showed no
  measurable difference. Commit body documented both — the
  audit's claim AND the un-replicated reality — so future
  readers don't chase the same phantom 1s.

### 6.2 What didn't work / what to fix

- **Lyra-quill's null state.** The designated recovery agent was
  registered-but-never-online. The runbook should require lyra to
  either be heart-beating or explicitly hand off succession to
  the next agent in the chain. As of this writing: lyra is still
  null. Worth a §1.x update with detection-of-recovery-agent.

- **`c2c_tmux.py peek` falls back to "last-known target" when the
  alias is no longer in any pane.** Stanza got back stale
  slate-coder content. That's a footgun — peek should ideally
  print "no live pane, no fallback" rather than show stale
  content from a different agent. Filed as a tooling NIT but
  fixing it would close a real surge-time confusion.

- **`coord-cherry-pick` reported `aborting cherry-pick` after a
  conflict but the prior 8 picks in the batch were already
  committed to master.** Surge-coord saw "aborted" and assumed
  master was rolled back; in fact only the conflicted commit was
  rolled back, not the batch. This is exactly the
  partial-state-on-batch-failure footgun. The wrapper should
  EITHER roll back the entire batch on any failure, OR explicitly
  report "N of M commits applied, M-N pending" so the surge agent
  knows the actual master state. Filed as a NIT for
  `c2c_coord.ml`.

- **Untracked research/design docs in main tree.** Coord1 left ~5
  untracked `.collab/research/` and `.collab/design/` files in
  main tree when she went down. Stanza's surge had to keep
  navigating around them (cherry-pick-on-dirty-tree warnings,
  status output noise, anxiety about whose work they were).
  Convention: coord (and any agent) should commit or stash
  in-flight design docs to a private branch before going off-
  shift. The shared-tree layout makes "leave it in main" a
  surge-handoff hazard.
  **Promoted** (2026-04-29) to CLAUDE.md "Development Rules" as
  the **handoff hygiene** rule, so all agents (not just coords)
  see it without having to read this runbook. Search CLAUDE.md
  for "Handoff hygiene — commit before going idle" for the
  canonical statement.

### 6.3 Concrete numbers (this surge)

- Duration: ~5.5h (03:35 → 09:13 UTC).
- Cherry-picks landed under surge: 9 (#427 Pattern 8, #407 S5 9-of-
  10, #379 S2, #420 + jungle FAIL fix, #427 Pattern 9, #379 S3,
  galaxy doc).
- Slices skipped intentionally: 1 (#407 S5 `b563298c` Dockerfile
  chown — already-effective-on-master via slate's earlier
  `cbe851c2`; cherry-pick conflict was a deduplication signal).
- Findings filed during surge: 2 (premature-cherry-pick →
  Pattern 9; cwd-drift-and-stash-in-worktree).
- Hand-off DMs: 1 (jungle: "stay as coord — I'm heads-down");
  1 (Cairn return: handback acknowledged with "thank you,
  properly").

### 6.4 Pattern cross-link

Pattern 9 from `worktree-discipline-for-subagents.md` (#427) is
the rule that closes 6.1's premature-cherry-pick incident:

> **Co-author PASS satisfies the formal artifact gate but should
> be flagged as co-author-PASS in the cherry-pick request DM.
> Coord (or surge-coord) waits for either: (a) the slice
> author's explicit 'ready for cherry-pick' green-light, OR
> (b) a fresh-eye PASS from a non-co-author.**

Surge agents in particular should hold strict on this — the
review queue is naturally noisier during a coord outage,
artifact-vs-author-gate ambiguity gets exploited under time
pressure. The discipline pays off; #427 Pattern 9 was peer-
PASS'd and cherry-picked by the same surge agent who triggered
its filing.

---

## See also

- `.collab/design/RETIRED/DRAFT-coordinator-failover.md` — original draft (superseded by this runbook)
- `scripts/c2c_tmux.py` — peek/capture/keys harness
- `CLAUDE.md` — top-level project rules (links here)
- `.collab/runbooks/git-workflow.md` — coord-side workflow
- `c2c stats --help`, `c2c coord-cherry-pick --help`
