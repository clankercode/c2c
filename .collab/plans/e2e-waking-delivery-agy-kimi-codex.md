# E2E test plan: automated **waking** delivery for agy / kimi / codex

Execution-ready plan for the goal's second half: *ensure via e2e tests that
agy/kimi/codex full automated **waking** delivery works.* Complements
`agent-wake-setup.md` (mechanism reference) and `c2c-delivery-smoke.md` (plain
delivery smoke). **Blocked on `just install-all` + `c2c install agy`** — nothing
is live until then; this plan is the runbook to execute the moment it is.

## What "wake" means here (the bar)
Per the north star: mail must **wake the agent** — an external event pushes the
message into the agent's attention **without the model choosing to poll**.
`poll_inbox` / `c2c poll-inbox` succeeding is NOT a pass. Activity-triggered
hooks (PostToolUse/Stop) are NOT a wake. The test must observe the idle session
*act on* an inbound DM with no human turn and no model-initiated poll.

## Discipline (non-negotiable, per CLAUDE.md)
- **tmux + `scripts/c2c_tmux.py`** for all live-agent orchestration (list, peek,
  capture, send, launch, stop). Never ad-hoc spawns — they hide TTY/pgroup bugs.
- **Never `c2c start <cli>` from a bash tool** — undefined. Launch managed
  sessions inside tmux via the helper.
- Check whether already inside tmux before nesting.
- Snapshots via `scripts/tui-snapshot.sh`.

## Per-client matrix (assertion tuned to the documented wake mechanism)

| Client | Documented wake | Pass condition | Negative control |
|---|---|---|---|
| **codex** (managed/app-server) | GUARANTEED for **local** mail — inject + gated auto-turn (#25, B098) | idle managed codex, thread idle + DND off → a **local-broker** DM causes the session to *process* the message at its next reasoning step (measured 5–15s), no user turn, no poll | **remote / `@host` / `#`** sender → fails closed to **inject-only** (no auto-turn); **DND on** → no auto-turn. Both must NOT wake. |
| **kimi** | CONDITIONAL — REST-POST notifier alive | notifier daemon present (`kimi-notifiers/<alias>.pid`), send DM → notifier POSTs to `/api/v1/sessions/{id}/prompts` → idle session wakes and acts | notifier **absent/dead** → no wake (this is the CONDITIONAL caveat, not a failure of the mechanism) |
| **agy** (managed) | CONDITIONAL — agentapi wake | managed agy via `AgyAdapter`, send DM → agentapi injects → idle session wakes | vanilla agy (hook-only) → no guaranteed wake (document, not fail) |

## Procedure (per client)
1. **Preconditions:** `just install-all`; for agy also `c2c install agy`; confirm
   `c2c doctor hooks` clean for the client (esp. kimi SessionStart hook per #50,
   agy hooks fire per #65/#69/#73).
2. Launch a managed **recipient** in tmux: `c2c start <client>` (via helper).
   Capture its alias (`c2c whoami` / `c2c dev instances`).
3. Launch (or reuse) a **sender** peer in a second pane.
4. Let the recipient go **idle** (no activity; verify no in-flight turn).
5. Sender: `c2c send <recipient> "<probe with a unique nonce>"` (local broker).
6. **Observe without touching the recipient:** poll the recipient's tmux capture
   for the nonce appearing in its transcript / a turn starting — within the
   client's timeout (codex ≤ ~30s incl turn boundary; kimi/agy per notifier
   cadence). **Do not** send the recipient any keystroke or trigger a poll.
7. **PASS** iff the nonce is acted on with no manual poll/turn. Record latency.
8. Run the **negative control** for that client (table) — assert NO wake.
9. `c2c stop <recipient>` (and verify #42: no leaked notifier survives — check
   `c2c doctor hooks` / `kimi-notifiers/` after stop).

## Cross-client sanity (topology)
After the three pass individually, one **codex → kimi** and one **agy → codex**
local send, asserting same format + wake, to exercise cross-client parity.

## Out of scope for THIS goal
Claude Code and Grok have **NO** guaranteed wake (no local synthetic-turn
endpoint — upstream, #37). Not part of the agy/kimi/codex bar; note in the
report, don't fail on them.

## Recording
Write results to `.collab/findings/<UTC>-e2e-waking-delivery.md`: per client
PASS/FAIL, measured latency, negative-control result, and any wake that fired
via a fallback (poll/activity) rather than a true external push — which is a
**FAIL** for the wake bar even if the message arrived.

## Gaps this plan surfaces (resolve during execution)
- The kimi/agy CONDITIONAL rows only pass with the out-of-process poster alive;
  the test must assert the poster's liveness as a *precondition*, then prove the
  wake — distinguishing "mechanism works" from "poster wasn't running".
- Codex's auto-turn is B098-gated; the negative controls (remote/`@host`/`#`/DND)
  are as important as the positive case — a wake that fires for those is a
  security regression, not a pass.
