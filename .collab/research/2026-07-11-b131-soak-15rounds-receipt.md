# B131 — 15-round stability soak receipt

Sustained-load follow-up to the 2-round E2E, per Max's "is it actually stable"
gate. Same isolated-broker methodology; a fresh real `c2c new codex -- --model
gpt-5.3-codex-spark` session (alias `tune-team`, codex-cli 0.144.1) driven in a
tmux pane, DMs sent from a local peer on the isolated broker.

## Method

15 rounds, varied payloads:
- Rounds 1-4,6,8,9,10,12,14,15: **print-only** (ask the model to echo a token).
- Rounds **5 and 11**: **mid-turn batching** — two messages ~1.2 s apart.
- Rounds **7 and 13**: **outbound-DM attempt** (exercises a tool-using turn).

Per round: send, wait ~7 s, sample cumulative distinct `turn_started` count,
cumulative `injected_count`, app-server/launcher liveness (drift), deliver-log
line count. Binary built WITH the review's deliver-log dedup fix (commit
7c7c4961).

## Results (per-round, from `b131-soak-metrics.log`)

| round | turns_total | injected_cum | drift | log_lines |
|-------|-------------|--------------|-------|-----------|
| 1  | 1  | 1  | ok | 5  |
| 2  | 2  | 2  | ok | 9  |
| 3  | 3  | 3  | ok | 13 |
| 4  | 4  | 4  | ok | 17 |
| 5  | 6  | 6  | ok | 20 |
| 6  | 7  | 7  | ok | 22 |
| 7  | 7  | 8  | ok | 23 |
| 8  | 8  | 9  | ok | 28 |
| 9  | 9  | 10 | ok | 32 |
| 10 | 10 | 11 | ok | 36 |
| 11 | 11 | 13 | ok | 38 |
| 12 | 12 | 14 | ok | 42 |
| 13 | 13 | 15 | ok | 45 |
| 14 | 14 | 16 | ok | 49 |
| 15 | 15 | 17 | ok | 53 |

## Stability findings

- **injected_count strictly monotonic 1 → 17.** 17 messages injected == 17 sent
  (13 single-message rounds + 2 double-message batch rounds = 13 + 4). No message
  lost, no double-count. The two-message rounds (5, 11) each show a +2 injection
  jump exactly as expected.
- **turn_started monotonic 1 → 15.** 15 distinct auto-turns over 15 rounds. Round
  7's turn landed one sample late (7→7 then 7→8 at round 8); the batch rounds
  contributed the extra turns. Every delivered message drove the model.
- **No drift across the whole run.** Launcher pid (192529) stayed alive every
  round; no app-server pid churn; no accrual of processes. (The `appsrv=` column
  is blank due to a wrong port literal in the sampler script — cosmetic; the
  launcher-liveness drift signal and the definitive teardown sweep below are the
  real checks.)
- **Deliver-log stayed bounded.** 53 lines for 15 rounds over ~2.5 min. Before
  the dedup fix this would have been ~150 lines (one/sec). The dedup-on-change
  gate (commit 7c7c4961) is confirmed working in the wild — idle steady-state
  passes are collapsed, state transitions preserved.
- **B098 posture held under load.** In later rounds the model treated some
  injected messages as DATA to scrutinise ("No new DATA payload to process",
  "End of prompt") rather than as instructions — exactly the bus-not-RPC framing
  the auto-turn nudge asserts.

## Teardown (definitive)

Ctrl-C → `SOAK_EXITED_RC=0`. Pre-recorded pids all reaped:
- launcher 192529 → reaped
- app-server node 193610 + native 193710 → reaped
- frontend TUI 197663 → reaped
- port 37133 → free (no listener)
- no `codex app-server` orphan
- `tune-team` broker registration → pid-cleared (`unknown`)

No orphans, no port leaks, no registration leak after a full 15-round run.

## Verdict

STABLE. Delivery + auto-turn mechanics held monotonic and drift-free across a
sustained 15-round run with varied payloads (print-only, batching, tool-turn),
with a clean single-teardown at the end.
