# Review — cross-repo flag implementation plan

Reviewed:
- Spec: `/home/xertrov/src/c2c/.collab/specs/2026-06-20-cross-repo-flag-spec.md`
- Plan: `/home/xertrov/src/c2c/.worktrees/cross-repo-flag/.collab/plans/2026-06-20-cross-repo-flag-plan.md`
- Relevant current source in the worktree: `ocaml/cli/c2c.ml`, `ocaml/c2c_repo_fp.ml`

## Verdict

PASS after plan edits.

The plan now covers the spec requirements for `list`, `send`, `register`, `monitor`, human-only empty-list hints, mutual exclusion with `--global`, precedence rules, and the softened `--from` identity error. It preserves the decisions Q1-Q4 and leaves `c2c_rooms.ml` untouched.

## Changes made to the plan

- Added explicit global constraints to preserve plain `send --session` behavior unless `--cross-repo` is supplied.
- Added a no-commit constraint, replacing the previous final task that told the implementer to commit by default.
- Clarified `cross_repo_flag` help text: explicit `--root` wins only where such a flag exists.
- Clarified the `list --global --cross-repo` mutex guard should run immediately after Cmdliner binders and before broker/output work.
- Fixed the send identity test command. The old `send --cross-repo --from alice hi` only exercises usage parsing; the plan now uses `send --cross-repo --from alice bob hi` to reach `validate_from_override`.
- Clarified `register --cross-repo` leaves `write_allowed_signers_entry` broker-local and must not touch the per-repo broker.
- Reworked the final handoff task to require review/dogfood/approval rather than an unconditional commit.
- Added risk notes for monitor positional argument threading and JSON list compatibility.

## Remaining notes for implementer

- Keep the monitor `const (fun ...)` parameter order exactly aligned with the `$ ...` term assembly.
- Keep `c2c list --json` empty output as `[]`; the sessions-broker hint is human-only.
- The original spec file is present in the main checkout, not under the worktree at the expected relative path, so use the absolute spec path above if needed during implementation.
