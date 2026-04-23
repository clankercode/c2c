# Residual Test Failure: `peer_renamed` Integration Case

Date: 2026-04-24
Author: codex
Scope: post-verification note for the delivery capability runtime slice

## Symptom

`python3 -m pytest tests/test_c2c_mcp_channel_integration.py -q` still has one
failing case after the channel-capability work is green:

- `TestPeerRenameGuard.test_peer_renamed_fires_when_same_pid_reregisters`

Observed failure:

- expected room history to contain a `peer_renamed` broadcast
- actual room history only contained the original
  `agent-old joined room rename-same-pid-test` entry

## How It Was Discovered

During final verification for the delivery capability slice:

- the capability-focused subset passed
- the full channel integration file was rerun as a broader regression pass
- only the `peer_renamed` test remained red

## Root Cause Status

Not investigated in this slice.

The failure does not appear related to the capability-gated channel delivery
changes:

- launcher env test passed
- capability-positive watcher tests passed
- capability-negative non-drain tests passed
- initialize catch-up test passed
- onboarding smoke passed

This looks like a pre-existing or separate instability in rename propagation /
room-history broadcast behavior.

## Fix Status

Unfixed in this slice.

## Severity

Medium for integration-suite cleanliness, low for the channel-capability change
itself.

The delivery slice is still verified for its intended behavior, but the full
`test_c2c_mcp_channel_integration.py` file is not globally green until this
rename case is addressed separately.
