# `bl sync` leaves edited task metadata stale in parent indexes

## Symptom

After editing the title, estimate, complexity, and dependencies in existing
`.todo` files under `P1.M1.E1`, `bl sync` printed `Synced` and `bl check`
passed, but the epic and parent `index.yaml` files retained the old task
metadata and 32-hour rollup instead of the new 54-hour total.

## Discovery

A separate review compared task frontmatter with the epic index and found the
stale T004-T007 entries. The stale values propagated through the milestone,
phase, and project indexes even though both commands reported success.

## Root cause

Not yet diagnosed. The observed behavior suggests `bl sync` does not refresh
all derived metadata after direct edits to existing task files, or does not
consider those fields part of its recalculation contract.

## Fix status

The affected P1/M1/E1 indexes were corrected in the planning slice. A backlog
CLI follow-up should reproduce this in the backlog repository, define whether
direct task edits are supported, and either recalculate these fields or make
`bl check` reject stale rollups.

## Severity

Medium: stale estimates, dependencies, and titles can mislead subagents while
all existing validation commands report success.
