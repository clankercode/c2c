# coordinator1 — standards reflections

Personal working notes on applying `ultra-code-standards` to my coordinator
role (not code). Committed so future-me can reread when sloppy.

## Why this file

Max loaded `ultra-code-standards` and told me to apply it metaphorically to
my general software-dev standards. The skill is concrete ("No file over 1,000
LOC"), not aspirational ("keep files small"). Same discipline goes for the
artifacts I produce as coordinator: sitreps, todo.txt, design docs,
dispatches, role files.

## The rules, metaphorically

### Soft / hard limits on artifacts

- **`todo.txt`** should not become a dumpster. If entries grow past ~60 items,
  regroup into sections (Done / In Progress / Blocked / Backlog) before adding
  more. Hard cap: if the file is over 500 LOC I've failed at pruning —
  aggressively archive completed items.
- **sitreps** are hourly snapshots. Each one should fit on a screen of
  thoughtful reading. If one sprawls past ~150 lines, the goal-tree / task
  sections need tightening, not appending.
- **design docs** (`.collab/agent-files/design-doc-v1.md`) have a single
  version-label shape. Past v10 means the doc has become a changelog, not a
  design — start a new one and link back.

### No duplicated status

- An item's state lives in ONE canonical place. Right now I've been
  duplicating across todo.txt / sitrep / design doc / swarm-lounge DMs.
  Going forward:
  - `todo.txt` = task state (open/blocked/done). Single source.
  - `sitrep 09.md` = snapshot of everything at a point in time. References
    todo.txt entries, not duplicates.
  - Design docs = architectural intent. "Status" section at most one line;
    everything else flows from it.
  - DMs = transient dispatch. Never the source of truth.
- If I find myself copy-pasting the same description into two places, one of
  them should be a reference to the other.

### One responsibility per artifact

- `todo.txt` = task tracker.
- `todo-role-gen-test.txt` drifted into three concerns (testing process,
  missing-role queue, v1.1 schema extensions). Split next time I touch it.
- `.sitreps/PROTOCOL.md` = protocol spec; not a changelog.
- `.c2c/roles/<name>.md` = canonical role, not scratch notes.
- When I spot responsibility drift in a file I'm about to edit, fix it in
  that edit. If I'm not editing, leave it — scope discipline.

### Meaningful names / tight bug entries

- Every bug I log in `todo.txt` should be ≤ 2 sentences + a link to
  `.collab/findings/<dated>.md` for detail. Long-form writeups live in
  findings, not in the tracker.
- Entry names should describe the bug ("dry-run drops namespace blocks"),
  not the session context ("regression I found during ceo's work on v1.1").
- Dispatch DMs should name the action, not the back-story. "fix bug #N: …"
  beats "so I was looking at the output and noticed …".

### No TODO without a reference

- Every open item points at: a commit, a finding file, a PR, or a Max
  directive with timestamp. Orphan memos drift fastest.
- If I can't cite why it matters, it probably doesn't.

### Scope discipline — the biggest one

- The skill says "Do not refactor files you are not touching for the current
  task." My analogue: don't rework docs, dispatch policies, or role
  definitions unless the current task requires it. I have a strong pull to
  "while I'm here, let me also fix X" — resist it. Separate tasks, separate
  commits, separate cognition.
- This includes the sitrep: don't use the hourly sitrep as a vehicle to
  restructure the goal tree unless it's actually drifting. Three-sitrep rule
  from the protocol exists to prevent premature refactoring.

## Self-audit triggers

Re-read this file when:

- A sitrep takes more than 10 minutes to produce (signals drift).
- I've copy-pasted the same content to 3+ places in one hour.
- Max calls out sloppy communication.
- `todo.txt` grows by 10+ entries in one session without 10+ closures.
- I'm about to file a 6-sentence bug description.

## What I will not do

- Big cleanup sessions "while we have time" — violates scope discipline.
- Deleting or rewriting other agents' docs without checking — CLAUDE.md rule,
  also good hygiene.
- Renaming / re-orging existing directories (`.c2c/`, `.collab/`, `.sitreps/`)
  mid-session. If a structure is wrong, propose a slice, don't do it drive-by.

---
*Written 2026-04-22T09:38Z, after Max invoked `/ultra-code-standards` and
asked me to commit the reflection.*
