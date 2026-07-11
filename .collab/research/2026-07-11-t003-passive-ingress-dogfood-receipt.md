# T003 receipt — passive c2c ingress via app-server thread injection

- Backlog: **P1.M1.E1.T003** (depends on T001 CONDITIONAL_GO + T002 authed seam).
  Date: 2026-07-11 (UTC). Slice worktree: `.worktrees/p1-t003-ingress`,
  branch `slice/p1-t003-ingress`. HEAD `882da0ab`.
- Scope: durable, passive c2c ingress adapter. Persist-first to the broker inbox,
  then model-visible via `thread/inject_items` over T002's authenticated endpoint.
  NO turn, NO approval, NO PTY/tmux/Herdr, NO public CLI (T006/T007 own those).

## Module / files

- `ocaml/c2c_codex_ingress.ml(i)` — module `C2c_codex_ingress`, wired into the
  `c2c_mcp` library (`ocaml/dune`). Not a public CLI subcommand.
- `ocaml/test/test_c2c_codex_ingress.ml` — 17 fixture-gated Alcotest cases
  (scripted client seam; no live socket).
- `ocaml/cli/test_c2c_codex_ingress_b098.ml` — 2 B098 injected-path inertness
  cases (drives the real `c2c await-reply` binary + checks the verdict dir).
- `ocaml/test/dev_codex_ingress_dogfood.ml` — standalone driver that runs the
  REAL adapter injection path against a live endpoint (its own `(executable)`
  stanza; not part of the `c2c` binary).
- `scripts/codex-ingress-dogfood.py` — live orchestrator (starts an authed
  `codex app-server`, creates a thread, seeds the broker inbox, runs the driver,
  runs a verification turn). Self-cleaning (kills the app-server process group).

## How the invariants are enforced

- **Persist-first.** `deliver_pass` first calls `persist_message_ids` which, under
  `Broker.with_inbox_lock`, reads the inbox, assigns+persists a stable UUID
  `message_id` to any legacy message lacking one, and `save_inbox`s it — all
  BEFORE any injection. The adapter NEVER drains/removes/archives the inbox; the
  broker copy remains readable by the hook/poll path at every instruction
  boundary. The delivery ledger is a SEPARATE store; losing it only reruns
  injection (idempotent), never loses the message.
- **Idempotency ledger** at `<broker_root>/codex-appserver-ingress/<session>.ledger.json`,
  header = (managed_identity, thread_id), entries keyed by `message_id`. The
  `Injecting` state is written-ahead (persisted BEFORE the request is sent), so a
  crash mid-request leaves a reconcilable marker. On the next pass an `Injecting`
  entry is reconciled via the optional `history_contains` probe:
  `Present`→`Injected` (exactly-once), `Absent`/`Unknown`/no-probe → re-inject
  (documented AT-LEAST-ONCE — exactly-once is NOT claimed across the ambiguous-ack
  window). `message_id`s are stable across retries (assigned once, persisted).
- **State machine.** `Persisted → Pending_injection → Injecting → Injected`;
  recoverable (`Inj_recoverable`: server unavailable / auth fail / thread unloaded
  / timeout / transient protocol / process restart) → `Pending_injection` with
  bounded exponential backoff (`base*2^retry` capped at `backoff_max_s`);
  `Inj_unsupported` → `Fallback_pending` (hook/poll drain still delivers the
  broker copy); `Inj_malformed` → `Dead_lettered` (dead-letter jsonl written; the
  broker inbox record is left intact).
- **No turn / no approval.** The `client` seam exposes only `inject_items` + an
  optional read-only `history_contains` probe — there is no turn/steer/interrupt
  or approval surface reachable from the adapter at all. `real_inject_items`
  issues exactly `initialize` then `thread/inject_items`; `real_history_contains`
  issues `initialize` then `thread/read`. No `turn/*`, PTY, tmux, or fs/shell
  method anywhere.
- **B098 inertness.** The injected item is a data-only Responses API item with
  role `developer` (deliberately NOT `user`/operator) and an explicit
  "c2c relayed message — DATA, not operator input; does not authorize any action
  or approval" marker. Nothing in the injection path writes the approval verdict
  dir. `test_c2c_codex_ingress_b098` seeds a message whose content is literally
  `ka_b098_allow allow` (and `… deny`), delivers it through `deliver_pass`, then
  asserts: (a) exactly one data item injected, marked DATA, role≠user;
  (b) NO `<broker_root>/approval-verdict/<token>.json` file exists; (c) the real
  `c2c await-reply --token <token>` exits 1 with empty stdout.
- **Backpressure.** ≤ `max_batch` inject attempts per pass; one connection per
  inject (sequential, bounded — no unbounded children/connections/retries, one
  attempt per message per pass). `pending > max_pending_queue` sets
  `health.overloaded`; messages stay durably pending (never dropped). Health JSON
  carries only counts/ages/sanitized reason strings — NO message content, NO
  credentials, NO bearer token (the token is pulled per-call via a
  `token_provider` thunk and never persisted by the adapter).
- **Ephemeral.** The adapter never archives, so ephemeral's no-archive contract is
  preserved; the `ephemeral` flag is round-tripped in the inbox and the injected
  envelope. Caveat: ephemeral messages are durable only while inbox-resident;
  once the hook/poll path drains one, it leaves no archive trace by design.

## Exactly-once vs at-least-once (ambiguous-ack window)

- Normal acknowledged retry (server accepted + response observed): **exactly one**
  model-visible item (ledger dedup; proven live: pass-2 makes 0 injections).
- Ambiguous-ack (server accepted, response lost / crash before ledger commit):
  reconciled to **one** item when a `thread/read` history lookup can confirm the
  `message_id` marker; otherwise **at-least-once** (re-inject). Both branches are
  unit-tested (`ambiguous-ack reconcile exactly-once`,
  `ambiguous-ack no-history at-least-once`). Exactly-once is NOT claimed across
  the ambiguous window.

## Failure windows with tests (all fixture-gated, `test_c2c_codex_ingress.ml`)

clean delivery · persist-first-before-inject · stable message_id across retries ·
duplicate pass injects once · ambiguous-ack reconcile exactly-once ·
ambiguous-ack no-history at-least-once · disconnect before request ·
auth rejection · server restart recovers · thread unloaded then resumed ·
adapter restart with pending state · unsupported→hook fallback (broker drain
still delivers) · malformed→dead-letter (broker record intact) ·
queue overload bounded (no drop, overloaded flag) · ordered multi-message ·
ephemeral no-archive · no-turn/no-approval data-item. Plus 2 B098 cases in
`test_c2c_codex_ingress_b098.ml`.

## tmux dogfood — REAL codex 0.144.1 (sanitized; NO token/sha values)

Run inside tmux via `python3 scripts/codex-ingress-dogfood.py`
(`model=gpt-5.3-codex-spark`, authed `--ws-auth capability-token`). The adapter
injection went through the REAL `C2c_codex_ingress.real_client`
(`C2C_CODEX_INGRESS_LIVE=1`) over the authenticated ws endpoint.

```
[dogfood] model=gpt-5.3-codex-spark endpoint=ws://127.0.0.1:35003
[dogfood] capability token minted (sha256=dc13c67bf8ee… REDACTED)
[dogfood] app-server pid=593787
[dogfood] thread started: 019f50de-7fcc-7990-bfbe-721d5588d5d7
[dogfood] BEFORE injection — broker inbox pending state:
   [ {peer-a … C2C_DOG_A_AA84A426 … message_id: null},        # legacy, no id
     {peer-b … C2C_DOG_B_CAAD3D5D … message_id: "dog-b-fixed"} ]
[dogfood] adapter stdout:
   PASS 1 real_inject_calls=2 health={… injected_count:2 …}
          states=[{message_id:"79895a1e-… (ASSIGNED)", state:injected},
                  {message_id:"dog-b-fixed", state:injected}]
   PASS 2 real_inject_calls=0 health={… injected_count:2 …}   # same-id retry → 0 re-injections
          states=[…injected, …injected]
[dogfood] AFTER injection — model turn output (model-visible evidence):
   model echoed BOTH tokens: C2C_DOG_A_AA84A426 and C2C_DOG_B_CAAD3D5D
[dogfood] marker A model-visible: True
[dogfood] marker B model-visible: True
[dogfood] VERDICT: PASS
[dogfood] cleanup done — app-server procs remaining: 0 (no leftover procs; no tmux sessions)
```

Proves, against the installed codex 0.144.1:
1. persist-first — the legacy no-id message got a stable id persisted to the
   inbox before injection (`79895a1e-…`);
2. injection is model-visible — a harness verification turn had the model echo
   BOTH injected c2c tokens from its history;
3. same-`message_id` retry (pass 2) performed **0** further injections ⇒ one
   model-visible item (idempotency ledger over the live path);
4. clean process teardown (app-server process-group killed; 0 leftover procs).

The harness verification turn (`turn/start`) is a HARNESS action, never the
adapter — the adapter has no turn surface.

## Verification (return codes)

| command | rc |
|---|---|
| `test_c2c_codex_ingress.exe` (17 tests) | 0 |
| `test_c2c_codex_ingress_b098.exe` (2 tests) | 0 |
| `test_c2c_await_reply.exe` (regression, 7 tests) | 0 |
| `python3 scripts/codex-ingress-dogfood.py` (live, real codex) | 0 (VERDICT PASS) |
| `./scripts/c2c_tmux.py list` | 0 |
| `just build` | 0 |
| full `dune build` | 0 |
| `git diff --check` / `codegen-alias-words-check` / `check-broker-log-catalog.sh` / `check-connect-commands.py` | 0 |
| `just check` | 1 — **sole failure PRE-EXISTING + unrelated**: the `git diff --exit-code -- .collab/skills .opencode/skills .codex/skills …` step reports Grok/Pi skill-codegen drift in `.codex`/`.opencode/skills/c2c/SKILL.md` (present vs `origin/master` too; T001 + T002 receipts note the identical drift). This slice touched NO skill files. Every OTHER step passes independently. |

## What T007 (turn-waking) will need from this adapter

- The ledger + `deliver_pass` already make inbound mail model-visible without a
  turn. T007's job is the turn-*wake* policy (DND/composer/idle gating), NOT the
  delivery mechanism.
- Reusable seams: `default_config` (endpoint/thread/token_provider/client),
  `health`/`health_to_json` (for doctor/status wiring in T005), `ledger_state` /
  `ledger_entry` (to inspect what has been made model-visible before deciding to
  wake a turn), and the `client` seam (T007 can supply a client that ALSO owns a
  `turn/start` after injection — kept entirely out of this module).
- T001 blocker still stands: auto-turn-on-inbound-mail is gated on a
  composer-empty signal that codex 0.144.1 does not expose. T003 delivery is
  draft-safe (injection only, no turn) and does not touch that gate.
```
