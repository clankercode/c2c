# T004 receipt — typed-draft preservation proof (passive c2c ingress vs a real Codex remote TUI)

- Backlog: **P1.M1.E1.T004** (depends on T002 launcher + T003 passive ingress).
  Date: 2026-07-11 (UTC). Slice worktree: `.worktrees/p1-t004-draftproof`,
  branch `slice/p1-t004-draftproof`.
- Versions: **codex-cli 0.144.1** (`/home/xertrov/.bun/bin/codex`), test model
  `gpt-5.3-codex-spark`. c2c HEAD at run: `e42195ac`.
- Scope: VALIDATION/PROOF only. No new delivery code. Proves T003's passive
  `thread/inject_items` ingress (module `C2c_codex_ingress`, driven by the REAL
  `dev_codex_ingress_dogfood.exe` → `C2c_codex_ingress.real_client`, over a
  T002-style authenticated `codex app-server` endpoint) NEVER edits or submits an
  operator's composer draft, preserves order, and honours T003's per-ack-state
  idempotency guarantee.

## T007 implementation inputs (codex 0.144.1 — READ THIS before building auto-turn)

These protocol facts were established live and T007's turn-completion tracking
must be built on exactly them:

1. **codex 0.144.1 emits NO `turn/started` notification.** Do not wait for one.
2. **A turn's id is returned in the `turn/start` RESPONSE** (`result.turn.id`,
   `result.turn.status == "inProgress"`). Capture it there.
3. **Turn lifecycle is observed via `thread/status/changed`** (idle↔active), and
   `thread/read` returns the current thread `status.type`. Completion = a
   transition back to `idle`. `item/agentMessage/*` stream to the FRONTEND
   (primary) client, not to a secondary observer ws.
4. **An app-server `turn/start` CANNOT clobber the composer.** Proven live
   (T007-precursor A): a turn started via the app-server while a non-empty
   multibyte/multi-line draft is in the composer streams in the frontend AND
   leaves the draft byte-exact, cursor stable, composer editable — because the
   composer is frontend-only state the app-server never sees.
5. **The app-server does NOT self-serialize turns.** Proven live (T007-precursor
   B): a second `turn/start` while a turn is active is ACCEPTED as a distinct
   turn id (queued/interleaved), not rejected. **T007 must own its own
   queue-if-active policy** (gate on `thread/status/changed`/`thread/read`
   status), or it will fire concurrent turns.
6. **No composer-empty/draft signal exists** (T001) — auto-turn cannot know from
   the protocol whether a human is mid-draft. Passive injection (T003) sidesteps
   this by never starting a turn; any T007 auto-turn must adopt a policy that
   tolerates the residual draft race (the draft itself always survives, per #4).

## Deliverable / harness

- `scripts/codex-draft-preservation-e2e.py` — the T004 e2e harness. Modes:
  `preflight` (CI-safe, no codex spawn) and `run` (live, in tmux).
  **Reuse (no second launcher):** app-server launched with the T002 flag set
  (same argv shape as `scripts/codex-ingress-dogfood.py`); injection via the
  T003 dev driver `dev_codex_ingress_dogfood.exe`; TTY side via
  `scripts/c2c_tmux.py`'s `tmux()` primitive (imported); deterministic cursor via
  `tmux display-message '#{cursor_x} #{cursor_y}'`; deterministic composer bytes
  via `tmux capture-pane -p`.
- Exact commands (reproducible; Max can re-run):
  ```sh
  # CI-safe prerequisite check (no codex, no quota):
  python3 scripts/codex-draft-preservation-e2e.py preflight
  # full live matrix (MUST be inside tmux):
  python3 scripts/codex-draft-preservation-e2e.py run --rows all
  # a single row / subset, e.g. the no-model-turn rows:
  python3 scripts/codex-draft-preservation-e2e.py run --rows 1,5,6,burst
  ```
  Env knobs: `CODEX_BIN`, `C2C_DRAFT_MODEL` (default `gpt-5.3-codex-spark`),
  `INGRESS_DRIVER`, `C2C_T004_RUNDIR` (snapshot/log output dir).

## Evidence method (how each AC is proven deterministically)

- **Byte-exact draft.** The test draft is multibyte + multi-line:
  `café ☕ naïve — 日本語 DRAFT_MARKER_QZX` / `second líne ✓ 🚀 do_not_lose_me`
  (inserted via tmux bracketed paste — `load-buffer` + `paste-buffer -p` — which
  does not submit). The composer region is extracted from a `tmux capture-pane`
  snapshot (the **bottom-most** `›` block; transcript user-messages also start
  with `›`, so bottom-most selects the live input composer) and compared
  BYTE-FOR-BYTE before/after every arrival.
- **Deterministic cursor.** Cursor row/col from `tmux display-message
  '#{cursor_x} #{cursor_y}'` (never visual judgement). Compared as a position
  RELATIVE to the composer's first row (`cursor_y − composer_start_row`, `cursor_x`),
  which is the arrival-invariant quantity: unrelated chrome above the composer
  (rotating tips, the one-shot "Skill descriptions were shortened" warning, or a
  growing transcript during an active turn) shifts the absolute row but must not
  move the cursor *within* the draft. Reported abs→abs too.
- **No-turn proof — WIRE-LEVEL (a recording proxy in the adapter's path).** The
  T003 adapter connects to a transparent recording+faulting ws JSON-RPC **proxy**
  (`ProxyRecorder`) that forwards to the real app-server, so EVERY JSON-RPC
  method the adapter issues is recorded. For every passive arrival the harness
  asserts the adapter's wire traffic was ONLY `initialize` + `thread/inject_items`
  — **never** `turn/start|steer|interrupt|cancel`, never `fs/*`. This is
  non-gameable (it observes the actual bytes, not a status heuristic) and closes
  the codex-review gap that status-only checks could miss a steer or a second
  turn. It is corroborated by the protocol lifecycle: codex 0.144.1 emits **no
  `turn/started`** (a turn's id is in the `turn/start` RESPONSE; lifecycle via
  `thread/status/changed`), so a separate authed **observer** connection also
  confirms no idle→active transition on arrival and that an active turn's status
  never blips (⇒ not interrupted). The remote TUI talks to the app-server
  DIRECTLY (not the proxy), so the proxy never perturbs the draft.
- **Driver binding.** `run_adapter` refuses any `INGRESS_DRIVER` not under
  `_build/`, asserts a zero exit code, AND cross-checks the proxy's recorded
  `thread/inject_items` (with message ids) — a stale/fake driver that reported
  the expected counts but did no real injection is caught (zero wire injects).
- **Atomic-enough sampling.** Each snapshot captures frame A → reads the cursor →
  captures frame B and accepts only when the composer BLOCK is identical across A
  and B (retrying if mid-repaint), so a streaming repaint cannot desync
  `cursor_y − composer_start` (mask or fabricate a relative move).
- **Deterministic waits / teardown.** Every wait is a bounded poll on a
  state/event (port bind, composer render, frame-settle, draft-marker-in-composer,
  delivery state, thread status) with a timeout + actionable failure dump. No
  fixed sleeps where a state can be waited on (the row-5 retry is a
  delivery-state poll; the ambiguous reconcile is a state poll). Teardown always
  runs (try/finally): observer closed, proxy stopped, tmux session killed,
  app-server **process group** SIGTERM/KILL, with a **per-owned-PID** cleanup
  receipt (our app-server pid alive before/after) and a proc count matched to
  OUR port only (never a concurrent unrelated codex run).

## Required scenario matrix — RESULT: 31/31 checks PASS (live, codex 0.144.1)

Single canonical run `--rows all` (run dir `…/t004-canonical2`; snapshots
`snap-NN-<tag>.txt`, `results.json`, `verification-pane.txt`,
`r6-hook-output.json`). Unique message id per row.

| # | Receiver state / composer | Result |
|---|---|---|
| 1 | Idle, EMPTY | composer BYTE-IDENTICAL + empty at prompt start; rel-cursor (2,0) stable; **wire methods = exactly [initialize, thread/inject_items]** (no turn); status idle→idle |
| 2 | Idle, NON-EMPTY, cursor mid-text | draft BYTE-EXACT; rel-cursor (23,1) stable; **wire = initialize+inject only** (no start/steer/cancel/submit). After-submit: operator Enter emptied the composer + thread went `active` (submission — not arrival — starts a turn) |
| 3 | ACTIVE generation, EMPTY | composer BYTE-IDENTICAL+empty (rel-cursor (2,0) stable) while transcript streamed; **wire had NO steer/interrupt**; same turn stayed active, no idle blip; injected 1 |
| 4 | ACTIVE generation, NON-EMPTY | draft BYTE-EXACT (rel-cursor (33,1) stable) during in-flight generation; **wire had NO steer/interrupt**; turn id stable; injected 1 |
| 5 | Adapter disconnect/reconnect, NON-EMPTY | **REAL connection loss** (proxy listener paused → adapter connect REFUSED) → `pending_injection` (durable, no loss); proxy resumed → `injected`; idempotent recheck inject_calls=0 ⇒ **exactly one model-visible item**; draft BYTE-EXACT before/during-outage/after; no turn |
| 6 | Ordinary NON-remote codex (hook-fallback CONTROL) | ordinary-codex draft BYTE-EXACT + rel-cursor stable across c2c arrival; message **pending at arrival**; then the REAL `c2c hook codex` at a UserPromptSubmit boundary emitted it as `hookSpecificOutput.additionalContext` AND drained it ⇒ **delivered ONLY at the hook boundary** (hook path NOT redesigned) |

**Burst + middle-retry (WIRE-proven order):** the in-path proxy recorded
`thread/inject_items` for the three ids in exactly `[burst1, burst2, burst3]`
order; re-running the same inbox (all ids already `injected`) recorded **0**
further wire injects ⇒ visible order 1,2,3 with the middle id injected **exactly
once** (wire count = 1).

**Ambiguous-ack AT-LEAST-ONCE (T003 contract), REAL response-loss, draft present:**
the proxy FORWARDS the `thread/inject_items` request to the app-server (which
processes it) but DROPS the response and closes the adapter → the adapter observes
`Inj_ambiguous` and persists `Injecting` (T003's real crash window, NOT a ledger
deletion). The `Injecting` entry is then reconciled on later passes: on this codex
`thread/read` exposes no item list so `history_contains` cannot confirm, and the
message is re-injected — the server received the inject **2× total** ⇒ documented
**at-least-once** (exactly-once explicitly NOT claimed across the window). Draft
BYTE-EXACT and no turn across the whole sequence. A SEPARATELY-LABELED secondary
case (`ambiguous/ledger-loss-recovery-at-least-once`) exercises ledger-loss
corruption recovery (re-inject after the persisted ledger is destroyed).

**Model-visibility verification turn:** a single harness `turn/start` asked the
model to echo the injected markers; the model echoed the injected markers (e.g.
`r1-…`, `r2-…`, `r5-…`, `burst1/2/3-…`, `ambig-…`) — read from the FRONTEND pane
(see lifecycle finding). Proves the injected items are model-visible.

## Assertion soundness — the checks have TEETH (offline negative-control test)

`scripts/test-draft-preservation-assertions.py` (no codex/tmux/quota — pure logic
over synthetic terminal snapshots; exit 0 iff every case holds) proves the
draft/cursor checks are NON-vacuous — they fail exactly when the draft or cursor
differs and pass only on true preservation. All cases hold:

- `composer_block` selects the BOTTOM-most `›` block (never a transcript echo of
  a submitted message — the exact trap that produced an early false result).
- `assert_draft_preserved` **FAILS** on: a single changed draft byte; a dropped
  multibyte char; a cursor move within the composer; a chrome-shift that ALSO
  moves the cursor (rel-cursor is not fooled). **PASSES** on: identical
  composer+cursor; a pure chrome shift (absolute row moves, rel-cursor stable).
- `assert_empty_preserved` is now a **byte-exact composer compare** (hardened per
  codex review — the earlier col≤2 check was vacuous for text inserted with the
  cursor left at the prompt start). It **FAILS** on: text inserted into the
  composer; a second composer line appearing; ANY composer-region change
  (fails-safe, never a false pass). **PASSES** only on an unchanged empty composer.

So a real draft edit or cursor move can never slip through as a pass — the
31/31 live result is a meaningful proof, not a green rubber-stamp.

## FINDING — the exact T003 lifecycle point where injected items become model-visible

`thread/inject_items` appends each item to the thread's **model-visible history
immediately** — the request returns an empty-object ack (`{}`) and the item is in
the thread's history at that instant. The model actually **consumes** it on the
**NEXT `turn/start`** (proven by the verification turn echoing the markers). The
injected item is **NOT rendered in the stock TUI transcript** — it is
model-history-only (consistent with T001). So "model-visible" = *present in the
thread history the moment inject_items acks; surfaced to the model on the next
turn*; it never appears on the operator's screen and thus never perturbs the
composer.

## FINDINGS — unsupported / notable protocol states (not assumptions)

- **codex 0.144.1 emits no `turn/started`.** Turn id is only in the `turn/start`
  response; lifecycle is observed via `thread/status/changed` (idle↔active). The
  harness uses that as the no-turn/active signal.
- **`item/agentMessage` notifications route to the FRONTEND (primary) client,
  not a secondary observer ws connection.** So model output (incl. the
  verification echo and an observer-initiated turn's stream) is read from the
  frontend tmux pane, not from observer notifications.
- **`thread/read` returns thread metadata + status only (no item list).** There
  is no item-count surface to diff; the no-turn proof therefore relies on status
  + `thread/status/changed`, and model-visibility on a real echo turn.
- **No machine-readable composer/draft signal exists** (re-confirms T001). The
  app-server never sees composer draft state — which is exactly why passive
  injection (and even a `turn/start`, see T007-precursor) cannot touch it.

## T007-precursor turn/start exploration (ADDED at coordinator request; SEPARATE from the passive matrix, informational — never gates the AC)

Drives the app-server control seam's `turn/start` directly (NOT the c2c delivery
path) to de-risk T007 (auto-turn on inbound mail). Results (real codex 0.144.1,
gpt-5.3-codex-spark):

- **A) `turn/start` WITH a live non-empty multibyte/multi-line draft:** the turn
  **streams in the frontend transcript** (rendered=True) AND the composer draft is
  **byte-exact preserved BEFORE / DURING streaming / AFTER completion**, cursor
  rel stable, and the composer is **still editable** afterwards. ⇒ An app-server
  turn cannot clobber the composer (frontend-only state) — strong de-risk vs the
  old PTY / tmux-send-keys submit path.
- **B) Turn serialization (fire `turn/start` while a turn is already active):**
  the second `turn/start` is **ACCEPTED as a distinct turn id** (queued /
  interleaved, NOT rejected). The draft survives byte-exact. ⇒ T007 must own a
  queue/dedupe policy; the app-server will happily accept concurrent turns.
- Reproduce: `python3 scripts/codex-draft-preservation-e2e.py run --rows t007`
  (or `--rows all`). Snapshots `snap-*-t7a-*.txt` / `snap-*-t7b-*.txt`.

## Verification (return codes)

| command | rc | notes |
|---|---|---|
| `python3 scripts/codex-draft-preservation-e2e.py preflight` | 0 | CI-safe |
| `python3 scripts/codex-draft-preservation-e2e.py run --rows all` | 0 | **31/31** matrix checks PASS; clean teardown |
| `python3 scripts/test-draft-preservation-assertions.py` | 0 | offline teeth-test — checks fail when the draft/cursor differs |
| `just build` | 0 | |
| `just check` | 1 | **sole failure PRE-EXISTING + unrelated**: `git diff --exit-code -- .collab/skills .opencode/skills .codex/skills …` reports the Grok/Pi skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` (present vs `origin/master`; T001/T002/T003 receipts note the identical drift). This slice touched NO skill files. Every other check step passes. |
| `./scripts/test-codex-delivery-tmux-e2e.sh` | 2 | prints `OBSOLETE` by design (the codex `--xml-input-fd` path was removed 2026-07-06); superseded by this focused e2e |
| `./scripts/tui-snapshot.sh 100 30 -- codex --version` | 0 | canonical TUI-snapshot harness exercised (rendered `codex-cli 0.144.1`) |

## Cleanup / process discipline

Every live run reports before/after process counts (matched to OUR port only)
and tears down, in a `finally` block (incl. on failure): the observer, the
recording proxy, the tmux session(s), and the app-server **process group**
(SIGTERM→SIGKILL). The teardown prints a per-owned-PID receipt (our app-server
pid alive before=True / after=False). Final canonical run: **procs on our ports
remaining after teardown = 0**; no leftover `t004*` tmux sessions; the row-6
control's isolated `CODEX_HOME` temp dir is removed and the user's real
`~/.codex` config is never modified. Pre-existing unrelated codex processes
(`codex-code-mode-host`, a `codex … resume`) were identified at start and never
touched.

## Review round — codex (`/ccc-review-cx`, gpt-5.6-terra xhigh) FAIL → fixed

The first codex static review returned **FAIL** with legitimate soundness gaps
for a *proof* slice; all were addressed in new commits (never `--amend`). The
central fix is a **recording + fault-injecting ws JSON-RPC proxy** placed in the
adapter's connection path:

1. **BLOCKER — active-turn no-turn proof was status-only** (a steer or a second
   turn could pass). Fixed: the proxy records EVERY adapter method; all rows now
   assert wire methods ⊆ {`initialize`, `thread/inject_items`} — a direct,
   non-gameable proof no `turn/*`/steer/interrupt was issued.
2. **BLOCKER — burst order not observed** (only counts). Fixed: the proxy records
   the injected message ids in order; burst asserts wire order `[1,2,3]` and the
   middle id injected exactly once; the retry pass records 0 wire injects.
3. **MAJOR — empty-composer check vacuous.** Fixed: byte-exact composer-region
   compare (catches inserted text even with the cursor at col ≤2); teeth-test
   updated.
4. **MAJOR — non-atomic capture.** Fixed: snapshots require the composer block
   identical across two frames bracketing the cursor read.
5. **MAJOR — driver not bound.** Fixed: `_build/` realpath check + zero-exit
   assertion + proxy cross-check of real injections.
6. **MAJOR — row 5 not a real disconnect.** Fixed: the proxy listener is paused
   (adapter connect REFUSED) then resumed — a real adapter↔server connection loss
   with the TUI/draft unaffected.
7. **MAJOR — ambiguous ≠ T003's path.** Fixed: the proxy forwards the inject
   request but DROPS the response (server accepted, response lost → real
   `Injecting`), reconciled to at-least-once; ledger-deletion kept as a separate
   labeled corruption-recovery case.
8. **MAJOR — row 6 not a real hook test.** Fixed: after proving no arrival-time
   mutation, the REAL `c2c hook codex` is fired at a UserPromptSubmit boundary and
   emits the message as `additionalContext` + drains it (boundary delivery).
9. **MAJOR — fixed `sleep(2.5)`.** Fixed: replaced with a delivery-state poll.
10. **MINOR — settle ignored / proc-count too broad.** Fixed: proc-count matched
    to our port; per-owned-PID cleanup receipt; atomic snapshot mitigates unstable
    frames.
11. **Receipt overclaims.** This receipt was rewritten to match what the harness
    now actually asserts (wire-level order/no-turn, real reconnect, real
    ambiguous, hook-boundary delivery), with concrete run dirs / snapshot paths /
    wire traces.

Re-run after fixes: **31/31** matrix checks PASS; teeth-test green; `just build`
0; `just check` 1 (pre-existing Grok drift only).
