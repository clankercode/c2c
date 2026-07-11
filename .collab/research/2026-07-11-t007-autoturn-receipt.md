# T007 receipt — safe auto-turn dispatcher for eligible local c2c mail

- Backlog: **P1.M1.E1.T007** (depends on T001+T002+T003+T004). Date 2026-07-11 (UTC).
  Slice worktree `.worktrees/p1-t007-autoturn`, branch `slice/p1-t007-autoturn`.
- Versions: **codex-cli 0.144.1** (`/home/xertrov/.bun/bin/codex`), test model
  `gpt-5.3-codex-spark`. Commits: `ca219135` (dispatcher + unit/B098 tests),
  `601a5b53` (live E2E harness + dogfood driver).
- Deliverable: `ocaml/c2c_codex_autoturn.{ml,mli}` — a per-recipient turn
  dispatcher layered on the T003 passive-ingress adapter. Wired into the
  `c2c_mcp` library (`ocaml/dune`).

## Composer-gating was INTENTIONALLY DROPPED (clean-design decision)

Per the coordinator/Max explicit decision, backed by T004's live proof, the
original spec's composer-state gating ("composer positively known empty",
"composer state unknown → fail closed", "composer non-empty → leave queued") was
**deliberately removed — NOT an oversight**. T004 proved live (codex 0.144.1)
that an app-server `turn/start` **cannot touch or clobber the operator's composer
draft** — the composer is frontend-only state the app-server never sees; a turn
streamed while a multibyte/multi-line draft stayed byte-exact and editable
(T004-precursor A, `.collab/research/2026-07-11-t004-typed-draft-preservation-receipt.md`
§ "T007-precursor turn/start exploration" + § "T007 implementation inputs").
There is no composer-empty signal in the protocol (re-confirmed T001) and none is
needed. Auto-turn does not depend on composer state. The dispatcher has NO
composer poll, NO composer gate, and never fails closed on a missing composer
signal.

## Design (what the dispatcher does)

One `deliver_pass`:
1. **Offline gate** (`session_active () = false`) → leave durably queued; NO
   inject, NO turn (B127 owns the sender result). `queued_reason=offline`.
2. **DND gate** (`is_dnd () = true`) → leave durably queued; NO inject, NO turn.
   `queued_reason=dnd`. Reevaluated on the next pass once DND clears/expires,
   through the same serialized dispatcher.
3. **Persist-first + inject** via T003 `C2c_codex_ingress.deliver_pass` — assigns
   + persists stable `message_id`s under the inbox lock BEFORE any turn, then
   injects each inbox message as model-visible DATA (idempotent, never drains).
4. **Advance/reconcile** the active batch: poll `thread/read.thread.status.type`;
   a running batch that has returned to `idle` is marked done and releases the
   serialization gate; an ambiguous/recovered-claim batch is reconciled if a
   history probe is available, otherwise HELD.
5. **Turn-eligibility**: an inbox message is turn-eligible iff LOCAL provenance
   (`from_alias` has no `@host` relay marker), injected (T003 ledger = Injected),
   and not already claimed by a batch. Remote-provenance mail is injected as DATA
   but NEVER batched into a turn.
6. **Serialize + fire**: if a non-terminal batch already holds the gate → do NOT
   fire (`active_turn`/`ambiguous_held`), accumulate. Otherwise, if the thread is
   idle and local mail is pending, coalesce it (ordered by broker seq) into ONE
   batch, **write-ahead persist `Batch_claimed` + the active pointer BEFORE the
   request**, issue exactly one `turn/start`, and record the turn id from the
   `turn/start` RESPONSE (codex 0.144.1 emits no `turn/started`). Never
   `turn/steer`, never `turn/interrupt`.

Durable turn-ledger at `<broker_root>/codex-appserver-ingress/<session>.turns.json`
(flock on `.turns.json.lock`), keyed by a stable batch key = `batch-<sha256(thread_id
+ ordered message_ids)>`. Metrics/logs (`pass_outcome_to_json`) expose queued
reason, batch/message ids, trigger/reconcile outcome, and a **redacted** recipient
(`rcpt-<sha256(managed_id)[:12]>`) — never bodies, credentials, or composer state.

## Turn-lifecycle protocol facts confirmed live (codex 0.144.1)

Probed directly this slice (scratchpad `probe_status.py`, isolated CODEX_HOME):
- `turn/start` RESPONSE returns `result.turn.id` + `result.turn.status="inProgress"`.
  No `turn/started` notification. Confirms T004.
- `thread/read` returns `result.thread.status.type`:
  `{"type":"active","activeFlags":[]}` while a turn runs, `{"type":"idle"}` when
  done. Reliably observable for a real (non-instant) turn. (A brief lag: an
  immediate read right after `turn/start` can still show `idle` before the turn
  engages — the dispatcher polls on a later pass, not in the firing pass, so the
  gate is not tripped by the lag.) The OCaml `real_thread_status` parses the
  compact re-serialized form (`"type":"active"`/`"inProgress"`/`"idle"`).
- App-server does NOT self-serialize (T004 Finding B) → the dispatcher owns the
  queue-if-active gate.

## State-matrix — unit tests (fixture-gated, no live socket): 14/14 PASS

`ocaml/test/test_c2c_codex_autoturn.ml` (scripted T003 inject client + scripted
T007 turn client):

| Row | Assertion | Result |
|---|---|---|
| offline | `session_active=false` → `offline`; 0 injects, 0 turns | PASS |
| DND on | `is_dnd=true` → `dnd`; 0 injects, 0 turns | PASS |
| DND clear | pass1 `dnd` (0 turns); clear → pass2 fires exactly 1 turn | PASS |
| idle local | 1 local msg → 1 inject + 1 turn; batch=[m1]; ledger `turn_running` | PASS |
| remote provenance | `peer@relay-a` → injected as DATA, 0 turns, `remote_only`, remote_pending=1 | PASS |
| active-turn batching + next-turn separation | turn1 fires [m1]; m2 arrives while `Active` → `active_turn`, NO 2nd turn; thread idle → batch1 completed + ONE follow-up turn [m2] only, distinct batch key | PASS |
| ambiguous ack held | `Turn_ambiguous` → `turn_ambiguous_held`; subsequent passes NEVER replay (start count stays 1) | PASS |
| ambiguous reconcile present | history probe `Present` → treated as running (blocked), not replayed | PASS |
| claim recovery (absent proof) | crash `Batch_claimed` + probe `Absent` → released, fires exactly once | PASS |
| claim recovery (no probe) | crash `Batch_claimed`, no probe → HELD, never replayed | PASS |
| idempotent restart | fresh config over same broker root, turn Active → `active_turn`, no refire | PASS |
| metrics hygiene | pass_outcome JSON leaks no body (`SECRET-BODY-XYZ`), no raw managed id; recipient is `rcpt-…` | PASS |

Run: `dune exec --root "$PWD" ocaml/test/test_c2c_codex_autoturn.exe` (via
`scripts/dune-build-locked.sh exec …`) → `Test Successful … 14 tests run` (incl. `remote provenance`, `canonical/#-form fail-closed`, `unknown thread status fail-closed`).

## B098 approval-isolation — 3/3 PASS (incl. positive control)

`ocaml/cli/test_c2c_codex_autoturn_b098.ml`: auto-turn a LOCAL message whose
content is literally `<token> allow` / `<token> deny` with an approval pending.
Asserts: the message is injected as a DATA developer item (marked "not operator
input", role ≠ `user`); the turn NUDGE carries NO verdict token/body and role ≠
`user`; **NO verdict file is created**; `c2c await-reply --token <token>` stays
unresolved (exit 1, empty output). Positive control: a genuine host-local
`c2c approval-reply … allow` DOES resolve `await-reply` (exit 0, prints `allow`)
— proving the inert assertions are non-vacuous. The dispatcher never writes an
approval verdict path; the turn only makes injected DATA model-visible.

Run: `dune exec --root "$PWD" ocaml/cli/test_c2c_codex_autoturn_b098.exe` →
`Test Successful … 3 tests run`.

## Provenance is FAIL-CLOSED (coordinator steer)

`default_provenance` treats a sender as `Local` ONLY when `from_alias` carries no
routing marker at all; ANY `@host` (relay-forwarded — exactly the broker's own
`is_remote_alias` marker, `String.exists ((=) '@')`) OR `#` (canonical
cross-host/room form) → `Remote` → durable+queued, never auto-turned. This is
stricter than a bare `@` test so a relay/canonical-form sender can never slip
into an auto-turn; anything ambiguous fails closed to queued. Tested by
`remote provenance` (`peer@relay-a`) and `canonical/#-form sender fails closed`
(`peer#somerepo`) unit rows.

## Live tmux E2E (smoke, 2 msgs) — real codex 0.144.1, gpt-5.3-codex-spark: VERDICT PASS

Harness `scripts/codex-autoturn-e2e.py` (isolated CODEX_HOME with copied
`auth.json` + minimal `config.toml`, NO user hooks; disposable broker root)
launches an authenticated app-server, starts a thread, and drives the REAL
dispatcher via `dev_codex_autoturn_dogfood.exe` (real inject + real turn
clients under `C2C_CODEX_INGRESS_LIVE=1`). Actual run:

- thread `019f5151-b4bf-73d1-9069-6f895e6780fc`.
- **A (remote no-turn):** `peer@relay-a` msg → `queued_reason=remote_only`,
  `turn_started=null`, injected as DATA (`remote_pending=1`).
- **B (local → real turn):** `peer-local` msg `at-m1` → **turn1 id
  `019f5151-b911-73a0-a19e-85a04edc3386`**, `batch_message_ids=["at-m1"]`,
  `batch-98608518761c7eefa61db995`.
- **C (serialization, REAL active window):** thread observed **active** during
  turn1 (`saw_active_gate=true`); a pass with `at-m2` present returned
  `queued_reason=active_turn`, `turn_started=null` — NO second concurrent turn.
  After idle: batch1 completed + **turn2 id
  `019f5151-d197-7950-a056-1b20a4554c59`** (≠ turn1) for
  `batch_message_ids=["at-m2"]` only (`batch-1c48a6f193f54ce4415015a5`). Ordered
  batching + next-turn separation proven with a real active window.
- **D (idempotency):** re-running 2 passes fired **0** new turns.
- **Model-visibility:** verification turn echoed `C2C_AT_M1_…` and `C2C_AT_M2_…`
  (both injected messages model-visible; the remote marker too, since remote mail
  is still injected as DATA — only its TURN is suppressed).
- **Cleanup:** owned app-server pid `1883668` alive_before=True / after=False;
  CODEX_HOME + broker_root removed; pre-existing codex pids
  `145661`/`3934717`/`3934917` untouched; no orphaned app-server.

Draft-safety of a turn (that it cannot clobber a live composer draft) is proven
by **T004** (linked above) — not re-proven here (this slice adds no new draft
risk: the same app-server turn seam T004 exercised).

## SOAK / stability E2E — real codex 0.144.1, gpt-5.3-codex-spark: VERDICT PASS

Headline stability evidence (coordinator/Max requirement). Harness
`scripts/codex-autoturn-soak.py` drives a SUSTAINED back-and-forth through the
REAL dispatcher: 15 rounds each direction (peer → managed codex auto-turns and
the model RESPONDS → thread returns to idle → next round), with 3 BURST rounds
(5, 10, 14) that inject 3 messages — one fired, then 2 more arriving mid-turn —
to test batching/serialization UNDER LOAD. Cumulative inbox (broker never
drains) so idempotency is exercised on every pass. Exact command:

```sh
SOAK_ROUNDS=15 SOAK_BURST_ROUNDS=5,10,14 python3 scripts/codex-autoturn-soak.py
```

Actual run (thread `019f515a-0b67-7f10-985e-56fc042a25fa`):

- **rounds_ok = 15/15**; `dropped_or_stuck = []` — every message auto-turned and
  the model responded (thread returned to idle each round); none stuck queued.
- **Serialization under load:** every burst round (5, 10, 14) reported
  `caught_active=True` (a REAL active window observed) + `mid_turn_blocked=True`
  (a pass while the turn was active fired NO second turn) + the two mid-turn
  arrivals batched into ONE follow-up turn (`extra_fired=[('s-rN-1','s-rN-2')]`).
- **18 turns fired, 18 DISTINCT turn ids** (no overlapping/duplicate turns);
  `dup_turn_ids = []`; `duplicate_batched_msg = []` — no message turned twice.
- **Idempotency at rest:** a final 2-pass re-run fired ZERO extra turns
  (`rerun_extra_turns = []`).
- **No drop + ordering:** the final echo turn listed **21/21** `C2C_SOAK_*`
  markers (`all_markers_seen=true`, `missing=[]`) in send order
  (`ordering_ok=true`).
- **No resource leak:** app-server proc-group child count + open-fd count were
  `{before:[2,20], after:[2,20]}` — zero growth over 18 turns + ~60 transient WS
  connections (each inject/turn/status call opens+closes one connection).
  `leak=false`.
- **No latency creep:** single-message rounds stayed ~1.6–3.1 s throughout
  (r1 3.11, r8 1.63, r15 1.87); burst rounds 4.8–7.5 s. No monotonic growth.
- **No crash / wedge / ledger corruption** across the whole run; clean teardown
  (owned app-server pid alive_before=True/after=False; CODEX_HOME + broker_root
  removed; pre-existing codex pids untouched; no orphaned app-server).

A short 3-round variant (`SOAK_ROUNDS=3 SOAK_BURST_ROUNDS=2`) is the CI-fast
smoke of the same harness (also PASS).

## Review round — codex (`/ccc-review-cx`, gpt-5.6-terra xhigh)

**Round 1: FAIL → fixed.** One legitimate BLOCKER: the pre-fire serialization
gate at `c2c_codex_autoturn.ml` only blocked on `` `Active ``, so an `` `Unknown ``
thread status (transient status-read failure / malformed-or-error response from
`real_thread_status`) fell through to `turn/start` — able to start a turn
concurrent with an in-flight one (the prohibited case). Fixed in a new commit
(never `--amend`): the gate now fires **ONLY on explicit `` `Idle ``**; both
`` `Active `` and `` `Unknown `` queue (`queued_reason` `active_turn` /
`status_unknown`, fail-closed) and retry on a later confirmable pass. Added
regression test `test_unknown_status_fails_closed` (asserts zero starts on
`` `Unknown ``, exactly one after `` `Idle `` is confirmed). This mirrors
`advance_active`, which already kept a running batch blocked on
`` `Active | `Unknown ``. **Round 2: re-review → PASS.**

## Verification (return codes)

| command | rc | notes |
|---|---|---|
| `just build` | 0 | |
| `just check` | 1 | **sole failure PRE-EXISTING + unrelated**: `git diff --exit-code -- .collab/skills .opencode/skills .codex/skills …` reports the Grok/Pi skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` (identical to the T001–T004 receipts' note). This slice touched NO skill files; the later check steps (`check-broker-log-catalog.sh` rc 0, `check-connect-commands.py` rc 0, `codegen-changelog-check` rc 0, `dune build`) all pass when run individually. |
| `dune exec --root "$PWD" ocaml/test/test_c2c_codex_autoturn.exe` | 0 | 14/14 |
| `python3 scripts/codex-autoturn-soak.py` (SOAK_ROUNDS=15) | 0 | soak VERDICT PASS (must run inside tmux) |
| `dune exec --root "$PWD" ocaml/cli/test_c2c_codex_autoturn_b098.exe` | 0 | 3/3 |
| `dune exec --root "$PWD" ocaml/cli/test_c2c_approval_paths.exe` | 0 | existing approval suite still green |
| `python3 scripts/codex-autoturn-e2e.py` | 0 | live E2E VERDICT PASS (must run inside tmux) |
| `./scripts/test-codex-delivery-tmux-e2e.sh` | 2 | prints `OBSOLETE` by design (legacy `--xml-input-fd` path removed 2026-07-06); superseded by the focused e2e above |

Exact E2E command (reproducible; must be inside tmux):
```sh
python3 scripts/codex-autoturn-e2e.py
# env knobs: CODEX_BIN, C2C_AUTOTURN_MODEL (default gpt-5.3-codex-spark), AUTOTURN_DRIVER
```

## Ownership / non-goals honored

Turn control ONLY via the authenticated app-server seam (T001/T002 + T003 inject).
FORBIDDEN paths never used: `turn/steer`, `turn/interrupt`, PTY writes,
tmux/Herdr input injection. T006 owns public grammar/aliases; T005 owns
doctor/status wiring; this module embeds no CLI policy (it is wired into the
library, not the public CLI — a follow-up slice surfaces it in `c2c start codex`
supervision).
