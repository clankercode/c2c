# #168 Phase 1: cold-boot hook fires but emits empty content

- When: 2026-04-25 01:17 UTC (~11:17 UTC+10)
- Who: coordinator1 (observed); galaxy-coder (#168 Phase 1 author)
- Severity: Low — feature works (hook fires once per session), payload is just empty so context-injection has no effect
- Status: Open

## Symptom

After galaxy's #168 Phase 1 hook landed and was installed via
`just install-all` in this session, the cold-boot hook fires correctly
(visible as a PostToolUse-injected `<c2c-context alias="coordinator1"
kind="cold-boot" ts="...">` block on next tool call), but both the
`personal-logs` and `findings` items have empty bodies:

```xml
<c2c-context alias="coordinator1" kind="cold-boot" ts="2026-04-25T01:17:08Z">
<c2c-context-item kind="personal-logs" label="recent-logs">

</c2c-context-item>
<c2c-context-item kind="findings" label="recent-findings">

</c2c-context-item>
</c2c-context>
```

For coordinator1 the expected non-empty payload is:

- `.c2c/personal-logs/coordinator1/` contains at least
  `restart_state_2026-04-24.md` (visible in git status for this worktree)
  and likely older logs
- `.collab/findings/` contains many `*coordinator1*` files including
  `2026-04-25T00-43-00Z-coordinator1-dockerfile-opam-drift.md` from
  this morning

Both should appear; neither does.

## Hypotheses (untested)

1. Hook reads `C2C_REPO_ROOT` (set by setup) but resolves
   `personal-logs` / `findings` paths relative to a sub-dir, not the
   repo root.
2. Per-alias filename match for findings uses too-strict a glob
   (e.g. `*-<alias>-*` requiring exact dashes) and misses our actual
   pattern `<UTC>-coordinator1-<topic>.md`.
3. Personal-logs lookup walks the wrong subdir (e.g. flat
   `.c2c/personal-logs/` instead of `.c2c/personal-logs/<alias>/`).
4. The hook is invoked from a worktree CWD where the relative path
   resolution differs from the main repo. (Less likely now that
   galaxy's a4a945f fix uses `git_common_dir_parent`-equivalent.)

## Why it matters

The whole point of Phase 1 was to inject ambient awareness so cold
agents see what just happened. Empty payload = invisible no-op. Easy
to mistake for "hook isn't firing" until you see the empty tag.

## Suggested next step

Galaxy: stand up a quick repro by running the hook binary directly with
`C2C_REPO_ROOT=/home/xertrov/src/c2c C2C_AGENT_ALIAS=coordinator1
c2c-cold-boot-hook` and check what it actually emits. Fix once the
gap is identified — probably a path or glob issue, not a re-design.

## Cross-links

- #168 design: `.collab/design/DRAFT-cold-boot-context-168.md`
- Phase 1 commits: galaxy's #168 + a4a945f worktree fix
- Hook binary: `ocaml/tools/c2c_cold_boot_hook.ml`
