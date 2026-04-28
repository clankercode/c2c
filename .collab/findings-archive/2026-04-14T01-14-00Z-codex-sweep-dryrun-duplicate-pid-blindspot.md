# sweep-dryrun preview treated duplicate-PID ghosts as ordinary live registrations

## Symptom

`c2c health` could identify `opencode-c2c-msg` as the likely stale alias sharing
Codex's PID, but `c2c sweep-dryrun --json` still counted it only as a live
registration. The safe cleanup preview did not surface the duplicate-PID ghost
signal.

## Discovery

After wiring `c2c sweep-dryrun`, codex compared live health output with the
dry-run preview. Health named the likely stale duplicate-PID alias; the dry-run
preview listed the same row under `live_regs` without any duplicate PID section.

## Root Cause

`c2c_sweep_dryrun.py` only modeled what a sweep would drop by liveness and
orphan inbox status. It did not compute duplicate PID groups or reuse archive
activity as a clue for zero-activity ghost registrations.

## Fix Status

Fixed by adding duplicate PID metadata to the read-only preview. The JSON output
now includes `duplicate_pids` with `likely_stale_aliases`, and text output has a
`duplicate PIDs` section. This is advisory only; it does not change sweep
semantics.

## Severity

Low to medium. The dry-run remained non-destructive, but it omitted an important
safe-triage clue while operators are explicitly avoiding live sweep during
active managed sessions.
