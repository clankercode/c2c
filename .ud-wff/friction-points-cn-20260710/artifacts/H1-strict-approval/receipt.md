# H1 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-h1-strict-approval`
- Tip: `85cf20cf9f369ebff57ddf8ad915d5d6188802cd`
- Range: `16a69c0b..85cf20cf` from base `c8d5e7c9`.
- RED: exact-token configured-supervisor local/relay-form allow and deny messages returned rc=0 instead of timing out rc=1.
- GREEN: await 6/6, approval_paths 23/23, notifier 23/23, embedded hook 27/27, shell hook 14/14; `just build`, `just check`, fresh review build, and diff check rc=0.
- Review-and-fix: independent fresh-cache PASS.
- Result: deprecated inbox verdict path/helper/options removed; peer messages inert; host-local verdict file/CLI still works.
- No install or push.


## Live peer-PASS addendum (2026-07-10, fable-warden)

- Repo live-peer gate satisfied: reviewed by fable-warden (Claude session, live peer, not slice author).
- Two FAIL rounds fixed in NEW commits (no amend): `fb9a7210` closed the OpenCode inbound-message
  permission-resolution path (surfaceAdvisoryMessage advisory-only; grep 0 hits for
  postSessionIdPermissionsPermissionId outside tests/docs; embedded blob byte-identical to TS) and
  trued the security ADR; `68124bdc` aligned 5 stale docs (incl public known-issues.md) to the strict
  host-local contract. Final tip: `68124bdc55014635429ec583713c8f5f58ed5113`, range c8d5e7c9..68124bdc.
- Reviewer-verified evidence IN slice worktree: just build rc=0; approval_paths 23/23; await_reply 7/7
  (canonical test_remote_message_cannot_reach_approval_path restored); notifier 23/23; embedded hook
  27/27; shell hook 14/14; just check rc=0.
- Signed peer-pass artifact: 68124bdc...-fable-warden.json (schema v2, build_rc=0, all targets).
- Follow-ups: bug B103 (question-flow message->action adjudication); vitest plugin harness pre-broken
  at baseline; approval-reply missing-arg error-message nit.
