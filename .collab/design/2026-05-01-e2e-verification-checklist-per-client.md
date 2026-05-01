# E2E verification checklist per client

- **Filed**: 2026-05-01T01:50:00Z by coordinator1 (Cairn-Vigil)
- **Driver**: Max directive 2026-05-01 — *"we should have an e2e
  verification checklist for all clients (maybe based on feature matrix,
  or just use feature matrix as source), and we should get an agent
  (stanza?) to go through and verify everything (using tmux etc as
  needed)."*
- **Tentative owner**: stanza-coder (verification pass), once she wakes
- **Source of truth**: `docs/clients/feature-matrix.md`

## Goal

A reproducible per-client smoke battery that an operator (or an agent
in tmux) can run to verify a client is a *first-class peer*. Each row
of the feature matrix becomes one or more checklist items with a
concrete reproducer + expected observable.

We have ad-hoc dogfood evidence for most rows but no canonical
"run-this-and-check-that" doc. The checklist closes that gap and gives
us a regression net for every client release.

## Clients in scope

1. Claude Code (project-scope `.mcp.json` install)
2. OpenCode
3. Codex (xml_fd deliver path)
4. Kimi (notification-store delivery, post-#473)
5. Crush (experimental — light-touch checklist OK)

Gemini CLI (#406) is pty/tmux-only; flag separately as "experimental,
limited matrix coverage."

## Checklist row template

For each feature matrix row × each client:

```
### <Feature>: <Client>

- **Setup**: exact commands + env to bring up the client
- **Action**: what the operator/agent does to exercise the feature
- **Expected**: the observable that confirms success
- **Failure modes**: known bugs / partial-coverage (link to findings)
- **Repro time**: typical wall-clock for one pass
```

Concrete example:

```
### Auto-delivery: Claude Code

- **Setup**:
  - `c2c install claude` (in repo)
  - `c2c start claude -n test-claude-N`
- **Action**:
  - From another peer: `c2c send test-claude-N "ping"`
- **Expected**:
  - Within ~2s, target's transcript shows
    `<c2c event="message" from="..." to="test-claude-N">ping</c2c>`
  - PostToolUse hook fires on next tool use
- **Failure modes**:
  - ECHILD race (fixed via bash wrapper, see commit XXX)
  - Channel-push selective miss (#387, fixed)
- **Repro time**: ~30s
```

## Surface of checks (≈ feature matrix columns)

For each client:

1. **MCP attachment**: `mcp__c2c__whoami` returns expected alias.
2. **Auto-delivery**: peer→client DM lands in transcript.
3. **Send-out**: `mcp__c2c__send` from client lands in peer.
4. **Room support**: `join_room` / `send_room` / `room_history` round-trip.
5. **Ephemeral DM**: `ephemeral: true` not in recipient archive.
6. **Deferrable flag**: `deferrable: true` doesn't push, surfaces on next poll.
7. **DND honoring**: `set_dnd true` suppresses channel-push.
8. **Auto-register**: alias persists across restart.
9. **Auto-join `swarm-lounge`**: `my_rooms` includes it on first session.
10. **Managed-instance lifecycle**: `c2c start` → `c2c stop` clean.
11. **Permission/approval flow** (where applicable):
    - Claude: PostToolUse hook fires
    - OpenCode: `c2c.ts` plugin permission DM
    - Kimi: PreToolUse hook → reviewer DM (currently broken — see
      `2026-05-01T01-47-18Z-coordinator1-kimi-hook-over-forwards-every-shell-call.md`)
12. **broker_root resolution**: client honors `C2C_MCP_BROKER_ROOT` env;
    canonical default falls through correctly.
13. **Inbox drain on init**: queued messages from while-offline are
    delivered on next session.

## Verification harness

The agent runs each item in tmux panes, captures pane content via
`./scripts/c2c_tmux.py peek`, and writes a result line per row:

```
[PASS|FAIL|SKIP] <client>/<feature>: <one-line note> (<repro-time>)
```

Aggregate output: `.collab/research/2026-05-01-e2e-verification-results-<agent>.md`.

`SKIP` is allowed for genuinely-not-applicable cells (e.g. Crush
ephemeral if Crush doesn't support that broker version).

## Slice plan (suggested, for stanza)

1. **Slice 1 (~1h)** — Author the checklist as
   `docs/clients/e2e-checklist.md`, sourced row-by-row from
   `feature-matrix.md`. Static doc; no execution yet.
2. **Slice 2 (~2h)** — Run the checklist against Claude Code +
   OpenCode (both already battle-tested). Capture results, file as
   research doc, update feature matrix `?` cells with verified
   verdicts.
3. **Slice 3 (~2h)** — Run against Codex + Kimi. Codex xml_fd should
   PASS; Kimi will likely surface known bugs (hook over-forward,
   any post-notification-store regressions).
4. **Slice 4 (optional)** — Crush + Gemini smoke (experimental
   coverage; expected partial).

Each slice = its own worktree, its own peer-PASS, single-author.

## Why this matters

- Feature matrix has `?` cells we've never confirmed (especially Crush).
- A new client (e.g. future Aider, Cursor agent) will need a known-good
  template to slot into; the checklist becomes the contract.
- Regression detection: re-run after any broker-side or plugin-side
  refactor to confirm no client lost a feature.
- Operator onboarding: an operator bringing a peer up for the first
  time gets a "did this actually work" doc instead of poking at it.

## Pre-handoff hints for the verifier

- Use `c2c start <client> -n <test-alias>` in dedicated tmux panes; do
  not run inline via Bash (CLAUDE.md "Development Rules").
- Test aliases should be ephemeral (`test-<client>-<rand>`) and
  `c2c stop`-cleaned at end of session.
- Where a feature is broken, file the failure as
  `.collab/findings/<UTC>-<alias>-<client>-<feature>.md` rather than
  fixing inline — keep the verification pass focused on
  *measure-the-state*, not *fix-it*.
- The whole battery should be re-runnable in ≤ 2 hours wall-clock once
  the doc is stable.

— Cairn-Vigil
