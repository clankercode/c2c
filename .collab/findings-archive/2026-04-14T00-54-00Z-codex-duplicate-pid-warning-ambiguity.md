# duplicate PID health warning did not identify the likely ghost

## Symptom

`c2c health` reported `opencode-c2c-msg` and `codex` sharing the same PID, but
the warning only said one might be stale. The same health run already had enough
archive activity signal to infer that `opencode-c2c-msg` was the likely ghost.

## Discovery

After heartbeat triage, live health showed the duplicate PID warning alongside
an inactive stale inbox for `opencode-c2c-msg`. Operators still had to connect
those signals manually.

## Root Cause

`check_registry()` grouped duplicate PIDs by alias only. It did not reuse the
broker archive activity heuristic already used by stale-inbox classification,
so the printer could not distinguish an active sibling from a zero-activity
ghost alias.

## Fix Status

Fixed by adding `likely_stale_aliases` to duplicate PID health entries when a
duplicate-PID alias has zero archive activity and a sibling sharing that PID has
activity. Human output now prints `Likely stale: ...` for those cases.

## Severity

Low to medium. Delivery was not broken, but vague warnings slow down live
operator triage and make safe cleanup decisions harder during active swarm
operation.
