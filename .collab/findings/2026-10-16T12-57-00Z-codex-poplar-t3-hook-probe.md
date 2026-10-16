# T3/Codex c2c hook delivery: parent-addressed mail reaches native subagent

Date: 2026-10-16. Severity: identity/routing isolation concern; observed delivery to native subagent, not established message loss. No implementation fix attempted.

## Context

T3 upstream installed commit `81493efb71e8e8244f95d3e9f71d8369654ab151`; c2c `0.18.2` (`a0b52e4b`). Current native Codex session `01a144c7-0113-7541-a32e-9d13712e5fe0`, c2c alias `codex-poplar-waffle-m0fg`.

## Observations

- First direct self-send was safely rejected by c2c; it did not test delivery.
- Temporary peer `t3-research-probe-20261016` sent an ephemeral marker ending `-A` at epoch `1792155354.542703`. Broker logged enqueue message ID `33147cfa-d422-484e-a9aa-72723d1c4635`, recipient native session above, `offline:false`. A later non-destructive peek returned an empty inbox. At inspection, no `response_item` of type `message` in the native transcript contained marker A. Copies in tool-call arguments/results are not receipt evidence.
- Repeated using temporary peer `t3-research-probe-20261016b`. Normal marker B was present in the raw inbox before the sending tool returned, and then appeared as a developer-role c2c envelope in the model transcript at `2026-10-16T12:57:03.797Z`.
- Ephemeral marker C also appeared as a developer-role c2c envelope at `2026-10-16T12:57:07.715Z`. Thus the anomaly is not evidence that all ephemeral messages fail.
- During independent review, the native research subagent reported that **it received A** as a developer c2c block, addressed to `codex-poplar-waffle-m0fg`, at header time `12:55`. It quoted the exact marker body. This resolves the apparent loss: the body reached the native child transcript instead of the parent's.

## Interpretation

Active-turn hook delivery works in this installed T3/Codex setup. The first test's empty inbox did not prove parent visibility. The native subagent has distinct CODEX_THREAD_ID `01a144c7-8498-7e02-9818-814354144ec9`; `c2c whoami --json` returns unregistered with `candidate:null`, and both c2c identity override variables are unset. Therefore do not explain this as a shared native ID. The independently read explorer transcript records A as a developer message at `2026-10-16T12:55:54.791Z`, line 150. The observed defect is cross-conversation delivery; responsibility between Codex hook routing, c2c, and T3 remains unresolved.

The separately created T3-owned test child reported a different native session/alias, demonstrating why native and T3-owned delegation must be tested separately.

The test did not exercise idle wake. The separate idle-child receipt accompanies the [main report](../research/2026-10-16-t3-code-c2c-support.md).

## Evidence and cleanup

- Native transcript: `/home/xertrov/.codex/sessions/2026/10/16/rollout-2026-10-16T23-54-15-01a144c7-0113-7541-a32e-9d13712e5fe0.jsonl`.
- Broker enqueue evidence: `/home/xertrov/.c2c/repos/8fef2c369975/broker/broker.log`.
- Explorer transcript: `/home/xertrov/.codex/sessions/2026/10/16/rollout-2026-10-16T23-54-48-01a144c7-8498-7e02-9818-814354144ec9.jsonl`.
- B pre-return inbox snapshot and command receipts: `/tmp/t3-c2c-installed/live-probe-b.json`.
- Temporary registrations A/B are removed at research closeout. No existing peer registration or application settings were changed.
