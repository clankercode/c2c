# Open Questions & Corrections (authoritative)

Two adversarial critics (feasibility + user-value) reviewed `00`/`01`/`02`.
Both verdicts: **solid-with-gaps**. The design direction is sound, but `00`/`01`
were written before this pass and contain **factual errors and stale/fabricated
data** in their mockups. Where they conflict with this file, **this file wins.**

---

## 1. Factual corrections (verified against live code + the live broker)

1. **FALSE: "`c2c list --json` collapses Unknown→`alive:false`."** It actually
   emits `alive: true | false | null` (`ocaml/cli/c2c.ml:648-652`) — the
   liveness **tristate is already preserved** (`null` = Unknown). → 01 §2.7's
   entire "read `registry.json` + reimplement `/proc/<pid>` start-time liveness
   in Python" workstream is **unnecessary**. Just shell out to `c2c list --json`
   and map `null → Unknown`. Deletes a whole MED-risk subsystem (PID-reuse +
   clock-tick parsing).
2. **The mockups depict a swarm that doesn't exist.** 00/01 show 7 alive agents
   (`coordinator1`, `lyra-quill`, `mm27-helio` trading PASS/build messages) and a
   busy `#swarm-lounge`. The **live broker**: 7 registry records, **0 alive**
   (`alive:false`/`null`), 15 archive rows that are **all bake-off test traffic**,
   `rooms/swarm-lounge/` has only `meta.json` + an **empty `members.json` (`[]`)**
   and **no `history.jsonl` at all**. The Rooms tab + the "member breakdown
   `5●1○`" cannot be produced from live data.
3. **The "room double-store dedup" is NOT the verified #1 lynchpin.** The
   `#<room_id>` `to_alias` tag is real in source (`c2c_broker.ml:3406`) but **zero
   live archive rows exhibit it**. The dedup rule must be built from the source
   format as a **test fixture**, not claimed as live-verified — and the
   **empty-room / no-history case is the COMMON path**, not an edge case.
4. **Registry fields in the Peers mockup don't exist.** Live `registry.json`
   records carry only `session_id / alias / pid / pid_start_time / registered_at
   / canonical_alias`. There is **no `role`, `dnd`, `compacting`, or
   `last_activity_ts`** — the Peers columns showing those are fabricated.
5. **`textual` is not installed** in system `python3` (`import textual` →
   ImportError). "Ships today, zero coupling" understates a real `.venv`
   bootstrap dependency — and the snapshot-test tier (the agent feedback loop the
   proposal leans on) can't run until that venv exists.
6. **Positive the design undersold:** the broker root is under `$XDG_STATE_HOME`,
   **not** `.git/`, so the browser **escapes the RO-git managed-session sandbox**
   — a genuine feasibility win worth stating.

(Also fixed: 01 had landed in `.collab/design/`; README cross-links pointed at
non-existent filenames. Reconciled.)

## 2. The sharper v1 (both critics converged)

- **KILLER FIRST VERSION = the Peers/roster pane + a live tail — not three tabs.**
  Max's ask decomposes to (1) "know who's alive" + (2) "watch them talk without
  ssh-ing into panes." The roster is **~80% already in `c2c list --json` +
  `registry.json`**. Ship that spine first; DMs/Rooms tabs follow once validated.
- **Reconsider "standalone Python tool" → make it `c2c watch` (a subcommand).**
  "Without ssh-ing into panes" means Max wants **one obvious thing to run**. A
  standalone `python3 scripts/browser/...` with a `.venv` re-exec is exactly the
  discoverability friction the brief complains about.
- **DM thread reconstruction is over-engineered for the primary ask.** Per-
  session-id archive sharding + bidirectional merge serves "read a full A↔B
  thread" (secondary). And **alias→session_id is NOT 1:1** — aliases churn
  session_ids across restarts and even share pids (live data) — so the join the
  DMs/Peers views assume is unsafe as specified.
- **Stepping-stone: ship a plain `c2c inbox/outbox/rooms` CLI FIRST** to validate
  the data model + dedup against real traffic before building the Textual +
  golden-snapshot edifice. The empty live rooms make this validation *more*
  valuable, not less.
- **Unbundle `02`.** The "existing TUI polish" is really **three unrelated
  workstreams** stapled together: (A) role-wizard **bug-fixes** (the dead
  `role_designer_embedded` fallback; `refine` hard-requiring `$TMUX` and
  `exit 1`) — genuine bugs, ship standalone; (B) **tmux-tool consolidation**
  (port `restart`/`grep`/`follow` from `c2c-swarm.sh` into `c2c_tmux.py`, delete
  `c2c-swarm.sh`) — arguably **higher immediate value than the browser** for the
  literal "without ssh-ing into panes" need, since `restart` (handles the
  "Background work running" dialog) only exists in the legacy script today; (C)
  the browser itself.

## 3. The one question that determines the whole product

**Does "watch my swarm talk to each other" mean the broker MESSAGE layer (DMs +
rooms), or the agents' actual REASONING / tool-calls?** The broker only captures
explicit `c2c send`s — a thin slice of what an agent is doing. The agents'
*thinking* lives only in pane scrollback (lossy/ANSI today). The design assumes
the former; the brief is ambiguous. **This single answer decides whether the
browser is the right artifact, or whether a better pane-aggregator is.**

## 4. Decisions for Max

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Broker messages vs agent reasoning** — what does "watch them talk" mean? | Answer first; it gates everything (see §3). |
| D2 | **Stack**: Python/Textual standalone vs `c2c watch` OCaml subcommand | Lean **`c2c watch`** for discoverability; Python only if a Textual prototype must ship this week. |
| D3 | **v1 scope**: roster-spine-first vs full 3-tab | **Roster + live tail first.** Add DMs/Rooms after a CLI validates the data model. |
| D4 | **Stepping-stone**: ship `c2c inbox/outbox/rooms` CLI before the TUI? | **Yes** — cheap, validates dedup/sharding against real traffic. |
| D5 | **Read-only vs send** | Read-only v1; "act" = shell out to `c2c_tmux.py send`, never reimplement PTY typing. |
| D6 | **Unbundle the tmux `restart` footgun + role-wizard bug-fixes** from the browser campaign? | **Yes** — ship A/B fixes from `02` as small standalone wins regardless of the browser decision. |

## 5. Remaining open questions

- What's Max's actual **day-to-day swarm size**? If it's rarely 7 live agents
  trading room chatter, the roster-only v1 matches reality far better than the
  three-tab design.
- How should the browser present an **alias whose archives belong to
  session_ids no longer in `registry.json`** (churn)?
- If/when an **events tab** lands: `broker.log` **rotates** at 10 MiB
  (`broker_log.ml`), so a naive byte-offset tail silently drops events across a
  rotation — must handle rotation, unlike the append-only `*.jsonl`.
- File **perms are 0600/0700** (`archive/`, `keys/`, inboxes); snapshot fixtures
  must be synthetic, never copies of real archive content to a world-readable tmp.
