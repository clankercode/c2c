# B109 peer-listing contract

## Decision

`c2c list` hides only registrations with the broker's explicit `Dead`
liveness state. `Unknown` remains visible: hook-driven clients can lack a
stable PID even though their next hook can receive a queued message.

`c2c list --all` is the explicit stale-registration/forensics view. It keeps
its existing extended session metadata and additionally restores confirmed-dead
local and relay rows. `--alive` remains the strict alive-only filter.

## Repository groups

`c2c list --global` already has the right boundary for cross-repository
discovery: it scans every known broker root and renders each visible broker as
its own repository section. Filtering must occur before rendering, so a
repository containing only stale registrations does not leave an empty group;
`--all` restores the group and its rows.

## Validation target

The CLI integration test seeds two canonical HOME broker roots, verifies the
live repository remains grouped and the dead-only group disappears by default,
then verifies `--global --all` restores that group. A separate pi-c2c worktree
owns the equivalent Pi presentation contract.
