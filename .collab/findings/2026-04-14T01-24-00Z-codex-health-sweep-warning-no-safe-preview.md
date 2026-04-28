# health sweep warning omitted the safe dry-run alternative

## Symptom

`c2c health` warned agents not to run `c2c sweep` while managed outer loops were
active, but it did not mention `c2c sweep-dryrun`, the safe read-only preview.

## Discovery

After wiring and improving `c2c sweep-dryrun`, codex checked live health again.
The active outer-loop warning still stopped at "do not sweep" and left the
operator without the next safe command.

## Root Cause

The warning predated the top-level `sweep-dryrun` dispatcher path. Once the safe
preview was available, the health text was not updated to point to it.

## Fix Status

Fixed by adding `Use c2c sweep-dryrun for a read-only cleanup preview.` to the
active outer-loop warning.

## Severity

Low. The existing warning prevented the dangerous action, but it missed an
actionable safe alternative during live cleanup triage.
