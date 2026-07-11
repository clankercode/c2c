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
- **No-turn proof (protocol-level).** codex 0.144.1 emits **no `turn/started`**
  notification; a turn's id is returned in the `turn/start` RESPONSE and the turn
  LIFECYCLE is signalled by `thread/status/changed` (idle↔active). A separate
  authed **observer** ws connection tracks those transitions and `thread/read`
  status. Passive arrival must produce **no transition to `active`** and leave
  `thread/read` status unchanged (idle stays idle; an active turn's id stays
  active with no idle blip ⇒ not interrupted/steered). The adapter structurally
  has no turn surface (T003) — it issues only `initialize` + `thread/inject_items`.
- **Deterministic waits / teardown.** Every wait is a bounded poll on a
  state/event (port bind, composer render, frame-settle across N consecutive
  captures, draft-marker-in-composer, delivery state, thread status) with a
  timeout + actionable failure dump (FAIL-*.diff written). No fixed sleeps where
  a state can be waited on. Teardown always runs (try/finally): observer closed,
  tmux session killed, app-server **process group** SIGTERM/KILL, before/after
  process counts reported.

## Required scenario matrix — RESULT: 26/26 checks PASS (live, codex 0.144.1)

Single canonical run `--rows all` (run dir `…/t004-canonical`; snapshots
`snap-NN-<tag>.txt`, `results.json`, `verification-pane.txt`). Unique message id
per row.

| # | Receiver state / composer | Result |
|---|---|---|
| 1 | Idle, EMPTY | composer stayed empty at prompt start; rel-cursor (2,0) stable; **no turn** (status idle→idle, no `active`); adapter injected 1 (health.injected=1) |
| 2 | Idle, NON-EMPTY, cursor mid-text | draft BYTE-EXACT; rel-cursor (23,1) stable (abs 22→22); **no start/steer/cancel/submit**; injected 1. After-submit: operator Enter emptied the composer + thread went `active` (submission — not arrival — starts a turn) |
| 3 | ACTIVE generation, EMPTY | composer stayed empty (rel-cursor (2,0) stable) while the transcript streamed; **same turn stayed active, no idle blip** (not interrupted/steered); injected 1 |
| 4 | ACTIVE generation, NON-EMPTY | draft BYTE-EXACT (rel-cursor (33,1) stable) during in-flight generation; **no extra turn, turn id stable**; injected 1 |
| 5 | Adapter disconnect/reconnect, NON-EMPTY | draft BYTE-EXACT before/DURING-outage/after; outage inject → `pending_injection` (durable, no loss); reconnect → `injected`; idempotent recheck inject_calls=0 ⇒ **exactly one model-visible item**; no turn |
| 6 | Ordinary NON-remote codex (hook-fallback CONTROL) | ordinary-codex draft BYTE-EXACT + rel-cursor stable across a simulated c2c arrival; **no arrival-time composer mutation**; the message stayed **inbox-pending** (delivered only at a UserPromptSubmit hook boundary; hook path NOT redesigned) |

**Burst + middle-retry:** 3 messages injected in ts order (`burst1/2/3` all
`injected`, inject_calls=3); re-running the same inbox (middle id already
`injected`) performed **0** re-injections ⇒ visible order 1,2,3 with exactly one
`2` on the acknowledged path.

**Ambiguous-ack AT-LEAST-ONCE (T003 contract), LIVE with a draft present:**
reproduced deterministically by deleting the persisted idempotency ledger between
two live passes (the exact "cannot confirm prior delivery" condition of the
ambiguous window): pass1 injected once, ledger removed, pass2 injected AGAIN ⇒
**at-least-once** (2 model-visible copies). Draft stayed BYTE-EXACT and no turn
across BOTH injections. (The natural crash-window race — server accepted,
response lost before ledger commit — is not deterministically reproducible on a
live socket; T003 also unit-tests it via a scripted client.)

**Model-visibility verification turn:** a single harness `turn/start` asked the
model to echo the injected markers; the model echoed 8 distinct injected markers
(e.g. `r1-…`, `r2-…`, `r5-…`, `burst1/2/3-…`, `ambig-…`) — read from the
FRONTEND pane (see lifecycle finding). Proves the injected items are model-visible.

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
| `python3 scripts/codex-draft-preservation-e2e.py run --rows all` | 0 | **26/26** matrix checks PASS; clean teardown |
| `just build` | 0 | |
| `just check` | 1 | **sole failure PRE-EXISTING + unrelated**: `git diff --exit-code -- .collab/skills .opencode/skills .codex/skills …` reports the Grok/Pi skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` (present vs `origin/master`; T001/T002/T003 receipts note the identical drift). This slice touched NO skill files (only added one `.py`). Every other check step passes. |
| `./scripts/test-codex-delivery-tmux-e2e.sh` | 2 | prints `OBSOLETE` by design (the codex `--xml-input-fd` path was removed 2026-07-06); superseded by this focused e2e |
| `./scripts/tui-snapshot.sh 100 30 -- codex --version` | 0 | canonical TUI-snapshot harness exercised (rendered `codex-cli 0.144.1`) |

## Cleanup / process discipline

Every live run reports before/after app-server & `--remote` process counts and
tears down the app-server **process group** + tmux session(s) in a `finally`
block (incl. on failure). Final canonical run: **app-server/remote procs
remaining after teardown = 0**; no leftover `t004*` tmux sessions; the row-6
control's isolated `CODEX_HOME` temp dir is removed and the user's real
`~/.codex` config is never modified. Pre-existing unrelated codex processes
(`codex-code-mode-host`, a `codex … resume`) were identified at start and never
touched (the proc-count pattern matches only our own `--listen ws://127.0.0.1` /
`--remote ws://127.0.0.1` invocations).
