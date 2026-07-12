# Transient FAIL in check-broker-log-catalog.sh under concurrent worktree builds

- **Date:** 2026-07-10T04:58Z
- **Reporter:** fable-warden (Claude, friction-points-cn closure run)
- **Severity:** low (flaky gate, false negative)
- **Status:** observed once, not reproduced; workaround = re-run

## Symptom

`just check` in `.worktrees/friction-h0-peek-auth` (tip `180eff1b`) failed rc=1 at
`./scripts/check-broker-log-catalog.sh`:

```
❌ FAIL: 1 emitter(s) missing catalog entry:
   - nudge_enqueue
```

`nudge_enqueue` IS cataloged (`.collab/runbooks/broker-log-events.md` has both the
severity-table row and the `### `nudge_enqueue`` heading at ~L674). Running the
script directly seconds later in the same worktree passed (`✅ catalog complete`,
29 emitters / 26 cataloged / 3 out-of-scope), and a full `just check` re-run was rc=0.

## Context

At the moment of the failing run, a second agent was concurrently running
`just build` / codegen recipes in a *different* worktree of the same repo
(`.worktrees/friction-h1-strict-approval`). No files in the H0 worktree changed
between the failing and passing runs (git status clean both times).

## Hypothesis

Unconfirmed. The script's emitter/catalog extraction presumably greps worktree-local
files, so cross-worktree interference shouldn't matter — unless part of the pipeline
shells out to git in a way that can hit shared-.git contention (index/optional locks)
and silently return partial results, which would make a "grep found nothing" read as
"missing entry". Worth checking the script for unchecked git/grep pipeline failures
(`set -o pipefail` + explicit rc handling on the extraction stages).

## Suggested fix

Harden `scripts/check-broker-log-catalog.sh`: fail loudly (distinct message) when an
extraction stage errors rather than reporting a missing catalog entry; or retry once
on mismatch. Until then: if the catalog check names an event that is visibly present
in the runbook, re-run before treating it as a real gap.
