# Hermes and P9 final completion audit

All currently tracked bugs above B370 are B371–B378. The audit read every
ticket, reopened incomplete B377/B378 acceptance, and completed those gaps.
P9 is 12/12 complete after its separate public proof and T004 review.

## Requirements and evidence

| Scope | Completion evidence |
|---|---|
| B371 | Integrated bounded fallback adapter and guidance; five actual idle mail/expiry/rearm wakes recorded in `~/.local/state/c2c-b371-evidence/20261022/final-live-wake-receipt.json`, with matching adapter hash. |
| B372–B375 | Per-session immutable identity, exact target/consent, staged first-turn handoff, selected ACK and atomic delivery reservations; deterministic regressions and independent review. The corrected-native real-manager rerun now passed on x-p35; see [native recheck](2026-10-23-hermes-integrated-native-recheck.md). |
| B376 | Explicit opt-in recommendation and isolated MCP connection identity; 60 setup/config and seven server tests plus actual Hermes discovery/identity/foreign-session refusal evidence in `/tmp/b376-handoff.md` and its linked receipts. |
| B377 | Pi and Codex/headless mappings, all-harness own/foreign/collision checks, compatible Pi extension registration and ownership-fenced legacy upgrade. Fresh host 28/28 and broker 8/8, worker and parent review PASS; see [namespace receipt](2026-10-23-b377-all-harness-validation.md). |
| B378 | Actual expanded Ink TUI and CLI send/inbound cards, literal/long/Unicode/control handling and exact selected DATA/ACK with integrated binary; [live receipt](2026-10-23-b378-live-terminal-validation.md). Fixed card-isolation verifier passes both archived surfaces and rejects eight counterexamples. Independent r2 PASS. Prior public regressions retain plain/non-TTY coverage. |
| P9 | [Public closeout](2026-10-23-p9-public-closeout.md), eight actual public two-host delivery/reply legs and original exact-binary native/install/fault/direct evidence; [T004 independent recheck](2026-10-23-p9-t004-independent-recheck.md) PASS. |

No new follow-up bug ID was needed: the identified gaps and verifier defect
were corrected under B377/B378, preserving the existing valid evidence.

## Integrated buildbox validation

Clean transferred candidate `77621fa9def483d5fb2e72d5036b3e1f5a92273e`, tree
`a8b40b8a6588a5e1f70762bc0f798511d6037668`, was checked in the isolated clone
`x-p35:/home/xertrov/src/c2c-hermes-final-29506fc2`. The directory name reflects
its initial candidate; the recorded checked-out SHA is authoritative.

Both commands exited 0 with bounded build parallelism:

```sh
env DUNEJOBS=2 DUNE_THROTTLE_JOBS=2 just check
env DUNEJOBS=2 DUNE_THROTTLE_JOBS=2 just test
```

The full recipe covered OCaml, Python, TypeScript, npm packaging, and T3
connector fixtures. Python reported 591 passed, 96 skipped and 143 subtests
passed. TypeScript reported 42 passed and one skipped. npm had 20 passes;
T3 development fixtures had 57. These are separate runner counts, not one
unique total. No forced repository-wide native test count is claimed for
this run; the recipe's native alias was invoked as written. Original P9
forced-test counts remain tied to b8, never relabeled for this candidate.

The later `2eabb2ef54c72f889a3cb26f6f57db5c71b3eca6` changes only the proof
script and its receipt. Its supplemental verifier ran on x-p35 with the
recorded positive/negative results, and a fresh integrated `just check` also
exited 0 at that SHA. The full product runtime is unchanged from the tested
77621fa9 candidate. No new installation or whole-tree validation receipt for
the installer is inferred from these scoped results.

All tracked source remained unchanged after the gates. The full test run
created only `.opencode/.opencode/c2c-debug.log` as an untracked test artifact.
Check/test logs and final source/binary identities are preserved under
`/home/xertrov/.cache/c2c/hermes-final-20261023/` with prefixes
`c2c-hermes-ship-77621fa9-` and `c2c-hermes-ship-2eabb2ef-`.

## Boundaries

Hermes native wake remains conditional on explicit consent, exact targeting
and a live supported router/watcher. MCP tools alone do not supply wake.
The paint proof starts no model, and the native fixture only proves enqueue
and request-context acceptance. Telegram client UI/transport and real model
outage were not newly proven. These limits remain explicit in the relevant
receipts and public guidance.

All final proof processes stopped. Command guards rejected recursive removal
of an older failed P9 scratch root and an initial isolated Hermes dependency
directory; both remain private, inert and disclosed. No deletion workaround
was attempted. The successful P9 run cleaned its own private roots and withdrew
public aliases; relay lease/reservation retention remains explicit.
