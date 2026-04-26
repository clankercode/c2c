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

## See also

- `.collab/design/RETIRED/DRAFT-coordinator-failover.md` — original draft (superseded by this runbook)
- `scripts/c2c_tmux.py` — peek/capture/keys harness
- `CLAUDE.md` — top-level project rules (links here)
- `.collab/runbooks/git-workflow.md` — coord-side workflow
- `c2c stats --help`, `c2c coord-cherry-pick --help`
