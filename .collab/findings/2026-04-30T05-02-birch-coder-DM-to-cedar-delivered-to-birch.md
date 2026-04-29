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
Reported to coordinator1. Confirmed as HIGH-severity. Awaiting task assignment for root-cause investigation.
