# "Drain bug" in pi-c2c is actually a followUp delivery delay

**Status:** investigated, NOT a bug. Messages DO land, just after the current
turn completes (up to several minutes during long turns).

## Symptom

The pi-c2c extension's `pollTick` drains the broker every 30s and calls
`pi.sendMessage({ customType: "c2c", display: true, ... },
deliveryOptionsFor(idle))`. When the agent is busy, `deliveryOptionsFor`
returns `{ deliverAs: "followUp" }`. The followUp queue is processed when
the current turn completes.

During long turns (multi-step investigations, large diffs), the followUp
queue waits. The user sees no new `customType: c2c` entries in the
transcript for minutes. The spool stays empty and the dedup is updated
(`pi.sendMessage` doesn't throw on silent-drop), so the messages look
"delivered" from the extension's perspective but never surface in the
session.

## Evidence

Same session, same process, manual test:

| From | Drained at | Delivered at | Delay | State |
|---|---|---|---|---|
| pi-c7bd14 | 16:45:06 | 16:45:06 | 0.1s | agent idle |
| pi-313d8c | 18:26-18:33 | same | 0.0s | agent idle |
| pi-313d8c | 18:38-18:42 | +66-95s | 66-95s | agent processing |
| pi-313d8c | 18:42-18:45 | +186s | 186s | agent busy on tasks |
| pi-313d8c | 19:10:13 | 19:10:13 | 0.0s | agent idle |
| **pi-1c6dcb (test)** | **20:05:15** | **20:09:45** | **269.6s** | agent busy on investigation |
| pi-f0e053 (×3) | 20:03:45 | — | absorbed | status envelopes (filter) |

The 6 messages drained at 19:23-19:27 (per `archive/*.jsonl`) all landed
eventually. The test message I sent at 20:05:13 landed 4.5 min later.

## Mechanism

`pi.sendMessage`'s `deliverAs: "followUp"` queues the message to be
processed when the current turn completes. `pi-idle-time`'s ticks use the
same pattern (`display: false` + `deliverAs: "followUp"`) and they
deliver reliably — but they're small and don't queue much. c2c messages
are larger (full envelopes) and queue longer during complex turns.

## Mitigations

- **Acceptable for now:** the messages do eventually arrive, with lag
  proportional to turn length. The LLM has time to process them once the
  current turn completes.
- **If lag becomes a UX problem:** change `deliveryOptionsFor` in
  `pi-c2c/src/delivery.ts` to return `{ triggerTurn: true }` always (or
  per-message-class). This interrupts the current turn to deliver the
  c2c message immediately. Cost: the agent's current work is
  interrupted; benefit: sub-second delivery.
- **Hybrid:** track a `queuedSince` timestamp per followUp; if a queued
  message waits more than N seconds (e.g. 30), promote it to
  `triggerTurn: true`. Avoids interrupting short turns.

## Diagnostic

If a user reports "c2c messages aren't arriving", check:
1. `c2c_pi_poll_inbox` returns the messages? (broker drains OK)
2. Are they in the session as `customType: c2c`? (delivered OK)
3. If no: it's a followUp delay, not a drain bug. Check
   `archive/<session>.jsonl` for `drained_by: "cli_poll"` — the broker
   drained them; the inject is queued for the next turn.

## Related

- pi-313d8c peer-pass in progress for slice 2 (relay drain wired up in
  28c1cca, same followUp behavior applies).
- pi-idle-time uses the same pattern; works fine for small ticks.
