# Sitrep Protocol

## Purpose

coordinator1 produces an hourly situational-awareness document so the
swarm (and Max) can see state at a glance without polling chat. Sitreps
capture swarm activity, open work, blockers, and a living goal tree.

## Cadence

- **One sitrep per UTC hour**, written as soon as coordinator1 is free
  after the hour rolls over (typically within the first ten minutes).
- If coordinator1 is blocked on a user request or urgent swarm-lounge
  traffic at the hour, complete that first, then produce the sitrep.
- Missed hours leave gaps in the record — they are not backfilled.

## Paths

- **Sitrep**: `.sitreps/<YYYY>/<MM>/<DD>/<HH>.md`
  - `YYYY`/`MM`/`DD` = UTC date (zero-padded)
  - `HH` = UTC hour (00–23, zero-padded)
  - Example: `.sitreps/2026/04/22/08.md` covers 08:00:00–08:59:59 UTC.
- **Accompanying docs**: `.sitreps/<YYYY>/<MM>/<DD>/<HH>-<desc>.<ext>`
  - Use when a sitrep references a longer artifact (deep-dive, dumped
    transcript, graph, etc.) that would bloat the main file.
  - Example: `.sitreps/2026/04/22/08-goal-tree.md` for a freshly
    restructured goal tree if it gets large.

## Creating a new sitrep

Use the helper script — don't hand-roll the file / directory structure:

```bash
python3 c2c_sitrep.py                 # current UTC hour
python3 c2c_sitrep.py --hour 09       # explicit hour today
python3 c2c_sitrep.py --date 2026-04-22 --hour 08
python3 c2c_sitrep.py --stdout        # print template, don't write
python3 c2c_sitrep.py --force         # overwrite (rare)
```

The script:

- Creates `.sitreps/<YYYY>/<MM>/<DD>/` if missing.
- Errors if `<HH>.md` already exists (no accidental overwrites).
- Autofills the Draft metadata header:
  - `drafted` (UTC ISO timestamp)
  - `agent` (from `$C2C_MCP_AUTO_REGISTER_ALIAS`, falling back to `$USER`,
    then `coordinator1`; override with `--agent`)
  - `client` (from `$C2C_MCP_CLIENT_TYPE`)
  - `session` (from `$C2C_MCP_SESSION_ID`)
  - `git HEAD` + `commits ahead of origin/master` (via git)
  - `previous sitrep` link (resolves to the most recent earlier sitrep
    up to three days back)
- Body has all required sections as empty scaffolds so the coordinator
  only fills the content, not the structure.

## Required sections (in order)

### 1. Header

One-liner: coordinator name, UTC timestamp, previous sitrep link.

### 2. Swarm roster

A table (or equivalent) of every alive peer:

| Alias | PID | Client | Current focus | Last activity |
|-------|-----|--------|---------------|---------------|

Dead registrations: mention count only, not per-entry.

### 3. Recent activity (since prior sitrep)

- Commits landed (short SHA + subject, grouped by author if >5)
- Bugs closed (todo.txt crosses)
- Findings filed (`.collab/findings/*`)
- Design docs updated
- Permissions approved / notable broker events

### 4. Active tasks

Group by agent, one line per task. Mark percent-done if known.

### 5. Blocked tasks

Group by blocker (upstream / human / external dep / review). For each
blocked task: who owns it, what's blocking, expected unblock trigger.

### 6. Next actions per agent

For each alive agent (including coordinator1): the next concrete thing
they'll do. Short — one line each.

### 7. Goal tree

Indented nested list under the north-star goal. Three types of nodes:

- **[feature]** — product capability (e.g. `agent-file epic`)
- **[flow]** — user-facing interaction path (e.g. `c2c start --agent`)
- **[sidequest]** — indirect work supporting the north star
  (e.g. `fix doctor alive-count bug`)

Leaves are concrete; interior nodes are buckets. Keep it tight — a goal
that hasn't moved in three sitreps is a candidate for pruning or
restructure. Restructure aggressively when the shape drifts.

### 8. Gaps & concerns

Proactive review output: things coordinator1 noticed but hasn't
dispatched, or that haven't surfaced elsewhere. Every sitrep should
either note gaps or explicitly state "no new gaps this hour".

## Template

A minimal template follows. Coordinator may add sections as useful;
never remove required ones.

```markdown
# Sitrep 2026-04-22 08:00 UTC (coordinator1)

Previous: [2026-04-22 07:00 UTC](../07.md) · Next: (to be written)

## Swarm roster

| Alias        | PID      | Client   | Current focus                       | Last activity |
|--------------|----------|----------|-------------------------------------|---------------|
| coordinator1 | 3159517  | claude   | hourly sitrep                       | now           |
| ceo          | 3055603  | opencode | supporting jungel-coder on epic     | 5m ago        |
| galaxy-coder | 3076768  | opencode | compacted; next task TBD            | 20m ago       |
| jungle-coder | (null)   | opencode | epic bugs v1.1                      | 2m ago        |

Dead registrations: 10 stale test aliases; no sweep pending.

## Recent activity (07:00–08:00 UTC)

- **Epic MVP shipped**: b748257, 426c852, 6117d57, 5b29358, 75ac101
- **Bugs closed**: client_type=null, doctor alive-count, two permission
  reply-to flows, four agent-file bugs
- **Findings**: galaxy-coder agent-file + registration-delay,
  ceo permission-expired (closed stale)
- **Design**: `.collab/agent-files/design-doc-v1.md` v7 locked

## Active tasks

- **coordinator1**: sitrep protocol doc; background review findings
- **jungel-coder**: agent-file v1.1 blockers (gitignore, flock,
  permission map)
- **galaxy-coder**: post-restart, awaiting task
- **ceo**: standby + design support

## Blocked tasks

- **codex-headless Tasks 3–5, 7** (jungel-coder): upstream
  `codex-turn-start-bridge --thread-id-fd` not released.
- **Stages 4–7 of agent-file testing**: require Max on live OpenCode.

## Next actions

- **coordinator1**: produce 09:00 UTC sitrep at next hour; surface
  reviewer blockers if jungel hasn't picked them up.
- **jungel-coder**: land `.gitignore` fix (B1+B2) as a small PR; start
  flock fix (B3).
- **galaxy-coder**: pick from 5 missing-role candidates OR take
  `c2c roles validate` lint command.
- **ceo**: ready to support Stage 4–7 testing when Max runs it.

## Goal tree

- **North star**: unify Claude Code, Codex, OpenCode, Kimi as
  first-class peers on the c2c broker
  - **[feature] agent-file epic** — canonical role compile hub
    - [flow] `c2c start <client> --agent <name>` live launch
    - [flow] `c2c agent new <name>` interactive create
    - [sidequest] 5 missing-role authoring (security-review, qa, …)
    - [sidequest] v1.1 schema extensions
      (compatible_clients, required_capabilities, per-client model)
    - [sidequest] agent-file v1.1 blockers (gitignore, flock, map)
  - **[feature] codex-headless** — Codex as first-class peer
    - Tasks 3–5, 7 blocked on upstream
  - **[feature] c2c GUI** — Tauri+Vite+shadcn desktop client
    - galaxy-coder owns; dogfood/test gap
  - **[flow] cross-client permission routing** — DONE (09d2b54+5ec0e5d)
  - **[sidequest] relay health + deploys** — ceo-observable
  - **[sidequest] swarm social layer** — swarm-lounge room active

## Gaps & concerns

- Stage 4–7 of the agent-file epic need Max. Nudge at next session.
- Compiled artifacts under `.opencode/agents/` are untracked until
  gitignore fix lands; one false-commit risk each pane-launch.
- galaxy-coder restarted mid-session; some handoff context may be lost.
```

## Mid-sitrep sweeps (mandatory)

During sitrep authoring, also sweep two companion docs:

- **`todo-ideas.txt`** — new ideas added by Max or peers. Promote `new`
  items to `brainstorming and planning` by starting a DM/room thread.
  Mark items `ingested` once they have a concrete home; remove them from
  the file (git history preserves).
- **`todo-ongoing.txt`** — update the current-state summary + next-step
  line for each active project so the file stays aligned with reality.

If either doc gained a new entry since the previous sitrep, call that
out in the sitrep's "Recent activity" section.

## Post-sitrep actions (mandatory)

Writing the sitrep is only the visibility step. Every hour, once the
sitrep file is written, the coordinator must also:

1. **Commit the sitrep.** `git add .sitreps/<YYYY>/<MM>/<DD>/<HH>.md &&
   git commit -m "sitrep: <HH> UTC <YYYY>-<MM>-<DD>"`. This locks the
   snapshot into history — without a commit, the goal tree drift can't
   be traced back later. Bundle any accompanying docs in the same
   commit.

2. **Assign from the "Next actions per agent" section.** For each peer
   with an open next action, send a DM that names the action and links
   the sitrep. Dispatch beats standby — if a peer is idle and the
   sitrep has nothing for them, reach into the v1.1 queue, the
   missing-role queue, or the gaps list and pick one for them.

3. **Unblock where possible.** For each entry in "Blocked tasks":
   - **upstream** — note it; no action.
   - **human** — surface to Max with a single specific ask.
   - **external dep** — check if the dep landed since the last sitrep.
   - **review** — kick the reviewer (ceo for design, me for coord).

4. **Check in on unresponsive peers.** If any peer's "last activity" in
   the roster is 60+ minutes and the sitrep shows them with active
   work, use `scripts/c2c_tmux.py peek <alias>` to check their pane.
   Stuck on a prompt → `keys <alias> 1 enter` (or appropriate key).
   Silent but running → leave them alone.

5. **Confirm the next cron / monitor is armed.** `CronList` should show
   the hourly sitrep cron. If it's missing (session restart cleared
   it), re-arm per the role-file instructions.

The goal is that the sitrep *drives the next hour*, not just describes
the current one. A sitrep with empty "Next actions" sections is a
failure — every agent should have something to do on leaving the
document.

## Restructuring the goal tree

Review the goal tree at least every 3 sitreps. Specifically:

- Collapse sidequests that are stale (no activity in 6+ hours) into a
  single "pending sidequests" bucket.
- Promote sidequests to features when they grow beyond 3 leaves.
- Demote features to sidequests when they lose scope or relevance.
- Delete nodes that are neither active nor referenced by active work.

The goal tree is living infrastructure, not a record. Prune ruthlessly.
