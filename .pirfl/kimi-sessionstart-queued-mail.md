# PIRFL — Kimi SessionStart surfaces already-queued mail (#12, mitigates #9)

## Goal
When `c2c hook kimi` handles **SessionStart**, non-destructively peek the
session inbox and surface the count of queued (non-system) messages in the
`c2c-session` identity skill, so a freshly-started Kimi session sees its
pre-startup backlog and can `c2c poll-inbox` — instead of the backlog sitting
silently until (or unless) the notifier drains it.

- Closes **#12** (SessionStart never surfaces already-queued mail).
- Mitigates **#9** (notifier strands pre-startup backlog / silent) by making the
  backlog visible to the recipient at session start. The deeper notifier
  delivery-reliability root cause needs a live-Kimi repro — tracked separately.

## Constraints
- **SAFETY: "bus, never RPC" (B098).** The peek MUST be non-destructive
  (`read_inbox`, never drain). The count is DATA written into an informational
  skill file — it must NOT deliver message content into any auto-action path,
  and must NOT trigger a turn or resolve any approval.
- Hook must never fail the host turn (keep the outer `try … exit 0`).
- Zero queued ⇒ no false nudge (don't regress the existing skill wording).
- Hermetic tests: `C2C_KIMI_HOOK_SKIP_NOTIFIER=1`; seed inbox in-process via
  `C2c_mcp.Broker.enqueue_message`, run the real `c2c.exe hook kimi` subprocess.

## Plan-slices
1. `c2c_setup.ml::write_kimi_session_identity_skill` — add `~queued_count` param;
   when `> 0`, add a queued-mail nudge line (count + `c2c poll-inbox`).
2. `c2c_hook_cmd.ml::hook_kimi_cmd` — after resolving alias, peek
   `read_inbox` and count `from_alias <> "c2c-system"`; pass `~queued_count`.
3. `test_c2c_hook_kimi.ml` — regression: backlog present ⇒ skill shows count +
   poll-inbox; zero backlog ⇒ no queued nudge.
4. Build (`scripts/dune-build-locked.sh --root <wt>`, `-j 2`), run
   `test_c2c_hook_kimi`, then adversarial subagent review, then merge+push.

## Log
- Implemented slices 1-3. `write_kimi_session_identity_skill` gained
  `?(queued_count = 0) ()`; hook peeks `read_inbox` (non-system count) and passes
  it; identity skill renders a `📬 You have N c2c message(s) already queued …
  poll-inbox` callout when `> 0`.
- Tests: `test_c2c_hook_kimi` 6/6 (4 existing + 2 new: backlog-surfaced,
  zero-no-false-nudge). `test_c2c_setup_kimi` 21/21.
- Dogfood: real `c2c send` ×3 from a peer → SessionStart hook → SKILL.md renders
  the accurate count. Non-destructive (messages stay queued; peek only).
- Pending: adversarial subagent review → merge+push.
