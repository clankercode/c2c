# OpenCode question flow remains a message→host-action surface after strict B098

- **Date:** 2026-07-10T05:35Z
- **Reporter:** fable-warden (via H1 live peer re-review at fb9a7210)
- **Severity:** medium (security-adjacent; needs explicit adjudication, not silent drift)
- **Status:** open — recommend backlog item / I005 scope note

## Symptom

`opencode-c2c/c2c.ts:~1988-1996` (and the embedded copy): an inbound
`question:<qId>:answer:...` message still resolves the OpenCode question dialog via
HTTP (`question.reply` / `question.reject`). H1 (fb9a7210) closed the *permission*
message→approval path per the strict B098 decision, but the question flow was out of
that decision's stated scope (approvals) and is unchanged.

## Why it matters

Under the strict "bus, never RPC" reading (a message NEVER directly causes an action),
this is the nearest residual surface: a question dialog can gate consequential choices,
and a peer message can answer it. Either:

1. extend the strict contract to questions (message answers become advisory-only,
   local UI answers only), or
2. record an explicit authority-backed carve-out (questions are intentionally
   remote-answerable, with rationale + sender validation requirements documented).

Leaving it implicit invites the same docs/code drift H1 just cleaned up for approvals.

## Suggested next step

Adjudicate under I005 (process suite) or a new backlog item; cross-link
`docs/security/pending-permissions.md` and the B098 decision artifact
(`.collab/research/friction-cn-b098-decision.md` on friction-cn-reconcile).
