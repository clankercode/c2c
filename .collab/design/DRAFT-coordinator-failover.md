# DRAFT: Coordinator failover protocol

**Status:** SUPERSEDED — operational protocol now lives at
`.collab/runbooks/coordinator-failover.md` (read that first).
This file remains as the original design notes.

**Originator:** Max (2026-04-25)
**Coordinator:** coordinator1
**Designated recovery agent:** **lyra-quill**

## Motivation

The swarm has a single coordinator (currently coordinator1 / Cairn-Vigil)
who is the routing/cherry-pick/decision bottleneck. If the coordinator
goes offline (quota exhaust, harness crash, compact loop, network
partition, killed terminal), the swarm stalls — peers DM coordinator1
and get nothing, no cherry-picks land, no peer-PASS → coord-PASS flow
completes.

We need a **designated recovery agent** who can detect the failure,
diagnose it, and take over coordinator responsibilities until the
primary coordinator is restored.

## Designated recovery agent

**Current:** **lyra-quill**

Why lyra: highest peer-review activity, broad context across all
slices, demonstrated coord-quality judgment (FAILed 4+ load-bearing
slices with substantive feedback this session), trusted with
git-workflow conventions, fluent in `.c2c/` layout.

Failover succession (if lyra also unavailable): jungle-coder →
stanza-coder. Decided by Max ad-hoc otherwise.

## Detection

Coordinator-down signals:
- DM to coordinator1 sits unread > 15min during normal session hours
  (peers should `c2c poll-inbox` from the coord's session via
  `scripts/c2c_tmux.py peek` to confirm).
- No sitrep at the expected `:07` mark.
- coordinator1's `c2c stats` shows compaction% trending high or
  active% near 0.
- Coordinator's tmux pane is at a shell prompt (claude exited) per
  `c2c_tmux.py peek <pane>`.

Lyra (or whoever is designated) should periodically — say hourly —
verify coord is alive even when not reaching out. The standing
`heartbeat 1h+13m "coord liveness check"` pattern would work.

## Diagnosis (recovery agent's first pass)

1. **Peek the coord's tmux pane** via:
   ```bash
   ./scripts/c2c_tmux.py list      # find coord pane
   ./scripts/c2c_tmux.py peek <pane>  # see current state
   ./scripts/c2c_tmux.py capture <pane>  # full transcript dump
   ```
2. **Check `c2c stats --alias coordinator1 --json`** for compacting
   state, last_activity_ts, registered_since.
3. **Check `c2c list`** — is coordinator1 still registered with a
   live pid?
4. **Check the broker inbox** — `mcp__c2c__peek_inbox` for queued
   messages addressed to coordinator1.

Common failure modes (to-be-grown as we encounter them):
- Coord at compacting state for > 5min — wait, then nudge with
  cache-keepalive tick.
- Coord at `Bash` prompt — claude exited; needs `./restart-self`
  by lyra in the coord's tmux pane (via `c2c_tmux.py keys` or
  `c2c-tmux-enter.sh`).
- Coord registered with dead pid — `c2c refresh-peer coordinator1
  --pid <new-pid>` or `c2c sweep` (carefully — only if coord is
  confirmed dead; see CLAUDE.md sweep guidance).
- Coord process running but stuck — diagnose via tmux peek; may
  need a manual interrupt.

## Takeover

Once coord is confirmed offline (not just transiently slow):

1. **Announce in `swarm-lounge`**: "lyra-quill assuming coord role
   per failover protocol. Reason: <symptom>. Will hand back when
   coordinator1 returns."
2. **Adopt coord responsibilities**:
   - Receive peer-PASS DMs (peers should re-route to lyra-quill on
     next DM if coordinator1 is unresponsive).
   - Cherry-pick to master with `C2C_COORDINATOR=1 git commit`
     bypass (lyra needs the bypass env set; recovery agents should
     have this enabled in their role frontmatter).
   - Run `just install-all` after each cherry-pick.
   - Decide push timing.
   - Drive sitreps at `:07`.
3. **Do NOT push to origin/master** unless absolutely necessary
   (relay-critical hotfix). Holding for primary's return is the
   default.
4. **Write a recovery log** at
   `.c2c/personal-logs/lyra-quill/coord-takeover-<UTC>.md` capturing
   what happened, what was done.

## Handback

When primary coord returns:
1. Primary announces in `swarm-lounge`: "coordinator1 back online,
   resuming coord role."
2. Lyra hands back: confirms in lounge, posts the recovery log.
3. Primary reviews the recovery log, updates docs / adds findings if
   the failure pattern was novel.

## Required tooling / state

- ✅ `scripts/c2c_tmux.py` — peek/capture/keys for diagnosing coord
- ✅ `c2c stats --alias coordinator1 --json` — health snapshot
  (S2+S3 just shipped)
- ✅ `mcp__c2c__peek_inbox` — see what's queued for coord
- ⚠️ `C2C_COORDINATOR=1` bypass — currently only configured for
  primary. **Lyra's role frontmatter needs this set conditionally
  with a "I am the active coord" toggle**. Suggested implementation:
  per-agent bypass flag in `.c2c/roles/<alias>.md` honored by the
  pre-commit hook.
- ⚠️ Coord-cherry-pick helper from wishlist would help here too.

## Action items

- [ ] Add this protocol summary to CLAUDE.md (short pointer to this doc).
- [ ] Set up lyra's role frontmatter with conditional coord bypass.
- [ ] Brief lyra on the protocol — currently she just got told via this
      doc landing. Send DM with the summary.
- [ ] Decide: should the standing `coord liveness check` heartbeat be
      armed in lyra's session by default?

## See also

- `scripts/c2c_tmux.py` — peek/capture/keys harness
- `CLAUDE.md` — top-level project rules
- `.collab/wishlist.md` — coord-cherry-pick helper, etc.
- `.collab/runbooks/git-workflow.md` — coord-side workflow
