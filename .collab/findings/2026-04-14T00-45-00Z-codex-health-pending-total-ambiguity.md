# health pending total hid below-threshold inboxes

## Symptom

`c2c health` reported inactive stale inbox artifacts with
`inactive total 14, total 28`, but only listed the two inactive thresholded
inboxes. The remaining 14 queued messages were below the stale threshold across
other inboxes, but an operator had to infer that from arithmetic.

## Discovery

After a heartbeat resume, codex checked live health. There were no actionable
stale inboxes, but the inactive-artifact summary showed a larger `total` than
`inactive total` without naming what the difference represented.

## Root Cause

`check_stale_inboxes()` counted all queued messages in `total_pending` and only
thresholded dead/unregistered artifacts in `inactive_pending`. It did not expose
an explicit below-threshold remainder count, so the text renderer could not
explain the difference.

## Fix Status

Fixed by adding `below_threshold_pending` and `below_threshold_inbox_count` to
the health JSON and printing a one-line remainder summary whenever thresholded
stale or inactive inboxes are shown.

## Severity

Low to medium. No messages were lost and no delivery path was broken, but the
operator output created avoidable ambiguity during live triage.
