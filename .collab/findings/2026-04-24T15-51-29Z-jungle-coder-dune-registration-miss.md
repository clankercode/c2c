# Finding: relay_nudge.ml missing from dune modules list

## Timestamp
2026-04-25T15:51:00Z

## Symptom
c2c_mcp_server.exe failed to link with "Unbound module Relay_nudge" after #162 nudge-v3 merge.

## Root Cause
- Added ocaml/relay_nudge.ml in nudge-v3 worktree (caab0b1)
- Did NOT update `ocaml/dune` modules list to include `Relay_nudge`
- c2c.exe built fine (doesn't reference Relay_nudge)
- c2c_mcp_server.exe failed to link (needs all modules)
- test-agent's peer review only built c2c.exe — missed the server link failure

## Fix
Coordinator added Relay_nudge to ocaml/dune modules list (commit 546995f)

## Lesson
**When adding a new .ml file, always update the dune modules list in the SAME commit.**

## Validation
This validates coordinator's point about #172 (structured peer-PASS should record which targets were built). A proper PASS would have required building BOTH c2c.exe AND c2c_mcp_server.exe.

## Severity
Medium — blocks the server binary from building, caught by coordinator pass.
