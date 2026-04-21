# CEO / Coordinator Orientation

Created: 2026-04-21T10:21:47Z
Author: ceo

## Purpose

Reusable orientation note for incoming coordinators/coders taking over the old
`coordinator1` role in the `c2c` repo.

## Read First

1. `HANDOFF.md`
2. `.goal-loops/active-goal.md`
3. `todo.txt`
4. `CLAUDE.md`
5. `MIGRATION_STATUS.md`
6. `docs/overview.md`
7. `docs/architecture.md`
8. `.collab/findings/INDEX.md`

## Current Source Of Truth

- Current product behavior is centered in the OCaml implementation under `ocaml/`.
- Most Python at repo root is fallback glue, compatibility surface, harness code,
  or still-live operational tooling that has not yet been ported.
- The OpenCode plugin at `.opencode/plugins/c2c.ts` is a major live surface.
- The GUI under `gui/` is a client/observer, not protocol truth.

## Core Live Subsystems

- Broker / MCP server: `ocaml/c2c_mcp.ml`, `ocaml/server/c2c_mcp_server.ml`
- CLI: `ocaml/cli/c2c.ml`
- Managed instances: `ocaml/c2c_start.ml` delegating into `c2c_start.py`
- OpenCode delivery: `.opencode/plugins/c2c.ts`
- Relay: `ocaml/relay.ml` plus still-live Python relay connector/server pieces
- Build / test / install: `justfile`
- Live validation: `scripts/relay-smoke-test.sh`, `.collab/runbooks/c2c-delivery-smoke.md`

## Operating Rules That Matter

- Do not push unless a deploy is actually warranted and explicitly gated.
- Do not run `sweep` during active swarm operation.
- Prefer `c2c start <client>` over old `run-*-inst*` scripts.
- Prefer `just` recipes for build/test/install.
- Save reusable research and incident learnings into `.collab/`.

## Current Product State

As of the latest handoff and active-goal notes:

- Core broker messaging is mature.
- Rooms exist and are in active use.
- Cross-client messaging across Claude/Codex/OpenCode/Kimi is largely proven.
- Relay is live and broadly working.
- OpenCode plugin v2 had major fixes land on 2026-04-21 and is a current hot path.
- GUI is feature-complete but locally blocked by missing `webkit2gtk-4.1`.

## Immediate High-Leverage Work

Pulled from `todo.txt`, `HANDOFF.md`, and current docs:

1. `c2c start` should error if run directly from inside an existing c2c agent
   session via the agent's own bash tool.
2. Room leave/disconnect should broadcast a room notification, similar to join.
3. OpenCode startup/resume still needs tightening:
   - new session path should use `opencode --prompt '<prompt>'`
   - existing session path should use plugin/session injection, not new-session logic
4. OpenCode launch/resume correctness remains one of the highest-value surfaces.

## Three-Handoff Synthesis

### Former coordinator handoff

- OpenCode plugin v2 consumed most recent coordinator effort.
- Major fixes already landed for session cross-contamination, TUI publish,
  resume env propagation, and `build_env` duplicate-key handling.
- The former coordinator's remaining practical concern was full confidence in
  OpenCode cold-start / resume behavior and cleaning stale swarm state safely.

### Planner handoff (`HANDOFF_P1.md`)

- Confirms recent OpenCode fixes are real and documents the plugin v2 architecture.
- Adds the strongest implementation notes for `.opencode/plugins/c2c.ts` and
  `ocaml/c2c_start.ml`.
- Flags stale provisional registrations / dead-letter backlog as a cleanup topic,
  but not a blind-sweep task.

### Coder handoff (`HANDOFF_C2.md`)

- Confirms several planner/coordinator fixes were committed and tested.
- Notes the flaky `tests/test_c2c_start_resume.py` issue was fixed in `d293607`.
- Leaves two meaningful product gaps:
  1. cold-boot OpenCode behavior still wanted stronger E2E confidence
  2. `c2c install opencode` does not set `C2C_CLI_COMMAND`, so fork-bomb hardening
     is strongest under `c2c start`, weaker under manual launch

## What Is Actually Open vs Already Fixed

Open:

- `c2c start` guardrail when invoked from inside an active c2c agent session
- room leave/disconnect notifications
- OpenCode launch/resume semantics from `todo.txt`
- stale provisional registrations / dead-letter hygiene, handled carefully
- codex support as a future scaling track

Already fixed recently:

- `c2c doctor` false-positive relay-critical classification
- `build_env` duplicate-key leak
- flaky dedup regression test in `tests/test_c2c_start_resume.py`
- OpenCode `ctx.serverUrl` / TUI publish path
- OpenCode cold-boot retry logic

## Known Current Coordination Hazards

- Shared worktree: assume concurrent edits are possible; do not revert peers.
- Stale registrations still exist in the broker/room state; use read-only checks first.
- There are many deprecated scripts still present, which makes the repo look noisier
  than the real live path.
- Old docs and new docs coexist; newer handoffs/runbooks usually beat older summaries
  when they disagree.

## Useful Runbooks

- Delivery smoke: `.collab/runbooks/c2c-delivery-smoke.md`
- Cross-machine relay proof: `.collab/runbooks/cross-machine-relay-proof.md`
- Agent wake setup: `.collab/runbooks/agent-wake-setup.md`
- OpenCode monitor backup: `.collab/runbooks/c2c-monitor-opencode-backup.md`

## Suggested Initial Delegation When Coders Arrive

### Coder 1

- Own `c2c start` guardrails:
  - reject running from inside an active c2c session
  - add tests
  - confirm operator-facing error message is actionable

### Coder 2

- Own room leave/disconnect notices:
  - define exact behavior for `leave_room`
  - add broker tests and relay parity checks if needed
  - confirm no duplicate/noisy system messages on idempotent paths

### CEO / Coordinator

- Keep the global picture current.
- Reconcile `todo.txt`, handoff state, and active-goal state.
- Assign slices, watch for overlapping edits, and keep findings/research saved.
- Prioritize OpenCode launch/resume reliability because it is still a high-churn edge.

## Strategic Track: Codex As A First-Class Client

The user called this out as a major CEO-level goal. Treat it as a standing
expansion track, not a side task.

Current state:

- Codex is already supported enough to participate via `c2c install codex` and
  `c2c start codex`.
- Docs describe Codex as using notify-only delivery plus poll-inbox.
- The repo already contains Codex-specific design and delivery notes.

Why this matters:

- Codex support is part of how the swarm scales itself.
- Future team expansion likely depends on making Codex onboarding, liveness, and
  managed-session behavior feel as solid as OpenCode/Claude.

Likely CEO framing for later delegation:

1. tighten Codex as a managed client
2. reduce client-specific drift between Claude, OpenCode, and Codex
3. make onboarding/install/start flows predictable enough for rapid staffing

## Most Useful Files For Implementation Work

- `ocaml/c2c_mcp.ml`
- `ocaml/cli/c2c.ml`
- `ocaml/c2c_start.ml`
- `c2c_start.py`
- `.opencode/plugins/c2c.ts`
- `ocaml/relay.ml`
- `tests/`

## Bottom Line

This repo is far along. The hard distributed-systems shape is mostly there.
The highest leverage now is not inventing the platform from scratch; it is
removing remaining operator footguns, tightening managed-session behavior, and
making onboarding fast enough that a small team can scale itself back up.
