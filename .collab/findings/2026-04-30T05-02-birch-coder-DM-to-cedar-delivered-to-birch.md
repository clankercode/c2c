# Routing Bug: DM to cedar-coder delivered to birch-coder

**Date**: 2026-04-30
**Aliases involved**: coordinator1 → cedar-coder (delivered to birch-coder instead)
**Severity**: HIGH — coordinator confirmed as routing-bug class; privacy issue for 1:1 DMs

## Symptom
A DM from `coordinator1` intended for `cedar-coder` (about pre-commit-pre-check sequencing, sentinel `__C2C_PREAUTH_DISABLED__`, lumi design review) appeared in `birch-coder`'s inbox. The message envelope had `from="coordinator1"` but `alias="cedar-coder"`.

## Discovery
birch-coder received the message in session heartbeat poll. Noticed the `alias="cedar-coder"` field in the envelope, which is the routing marker for the intended recipient.

## Confirmed routing-mismatch class — 3 data points (coordinator1):
1. Test-agent's 2026-04-29 cross-recipient-DM-misdelivery report
2. 2026-04-29 17:58: self-DM echo via cedar route
3. 2026-04-30: DM to cedar-coder delivered to birch-coder

Pattern is real, not noise. Coordinator filing as HIGH-severity routing bug task.

## Possible root cause (coordinator hypothesis)
Broker's inbox-write path may have an alias-substitution vulnerability — possibly when to_alias resolution falls back via canonical-alias matching against an indexed prefix, OR when channel notification fan-out duplicates to an unintended recipient.

## Status
MITIGATED (2026-05-04) — not reproduced since April 30. Multiple mitigations now in place:
1. Case-insensitive alias resolution (c2c_broker.ml:1459, `alias_casefold`) prevents asymmetric eviction that was one plausible root cause
2. Multi-alive-count detection (c2c_broker.ml:1467-1472) logs when duplicate alive registrations exist for the same alias — the smoking gun for this bug class
3. Per-DM dm_enqueue trace logging (c2c_broker.ml:2110-2122) records to_alias + resolved_session_id + inbox_path unconditionally, providing diagnostic data if this recurs
4. Casefold guards (9a0cd880, e3c6aba0, b8ca6cb0) on register-time eviction

Root cause was never definitively identified — could have been a transient multi-registration race during high-load (10+ subagents during quota-burn). If reproduced, the dm_enqueue trace will reveal whether the session_id resolution was wrong or the inbox_path was wrong.
