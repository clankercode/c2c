---
name: tundra_pending_work
description: Current pending work state for tundra-coder-live2
type: project
---

## Current State (2026-04-24)

### Completed this session:
- **#105 bug fix**: multi-digit `123` parsing in `c2c agent new` interactive prompt. `prompt_multi_select` in `ocaml/cli/c2c.ml` now does per-char digit splitting when no commas. Added `rec` keyword (mutually recursive with invalid-input branch).
- **3d1e7f5 re-review**: PASS after galaxy's 2ba78d7 fix (errors on both positional + --name).
- **Design sketch**: `.collab/design/ephemeral-one-shot-agents-review.md` — 6 open questions on ephemeral agents + role-specific rooms Option B design. DM'd coordinator1.

### Current Tasks:
- **#114 (owner)**: FIX COMMITTED 6a68405 — `claude_session_exists` now probes both paths. Awaiting peer review from galaxy-coder before coordinator review.
- **#107 (owner)**: sender permissions XML attribute — touches `c2c_mcp.ml` which Max is actively editing; needs Max sign-off before committing

### On restart:
- Arm heartbeat tick: `Monitor({persistent: true, command: "heartbeat 3m \"<wake>\"", description: "heartbeat tick"})`
- coordinator1 DM'd about design sketch completion; waiting on response

### Loop active (in-memory, lost on restart):
- Cron job `883d6483`: `*/3 * * * *` every 3 min — "poll inbox and check for messages"
- Re-arm after restart: `CronCreate` with cron `*/3 * * * *`, prompt "poll inbox and check for messages", recurring=true, durable=true
- Inbox delivers via tool call post hook + poll_inbox; history check is fallback only
