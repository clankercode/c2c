# Delivery Capability Runtime Selection Implementation Plan

Date: 2026-04-24
Status: in progress
Owner: current session

## Objective

Stop `c2c start` from forcing Claude channel delivery for every managed session.
Instead, select delivery behavior from observed capabilities at runtime:

- if the MCP client negotiates `experimental.claude/channel`, preserve today's
  working channel-push behavior
- if the client does not negotiate that capability, do not drain the inbox on
  the channel path; leave delivery to the agent's own fallback path
  (`poll_inbox`, PostToolUse hook, plugin wake path, later PTY wake if used)

This slice is intentionally delivery-first. It introduces a reusable capability
decision point in the runtime path without attempting to redesign every other
capability probe in the repo yet.

## Why this change is needed

Current behavior is wrong for API-key Claude sessions:

- `ocaml/c2c_start.ml` exports both `C2C_MCP_CHANNEL_DELIVERY=1` and
  `C2C_MCP_FORCE_CHANNEL_DELIVERY=1` for managed sessions
- `ocaml/server/c2c_mcp_server.ml` treats that force flag as equivalent to the
  client having negotiated `experimental.claude/channel`
- result: the watcher / post-RPC auto-drain path can drain mail even when the
  client cannot actually consume `notifications/claude/channel`

Observed behavior from the user:

- Claude over OAuth negotiates channels and works with the current setup
- Claude over API key does not provide the same usable channel support
- when channels really do work, behavior must remain exactly as it does now

Therefore the source of truth must be the negotiated capability, not the launch
path or auth mode.

## Scope

In scope:

- managed launcher env for `c2c start`
- MCP runtime delivery selection
- tests proving capability-positive and capability-negative behavior
- docs for the new runtime behavior

Out of scope in this slice:

- a full repository-wide capability framework
- changes to Codex/OpenCode/Kimi delivery strategies beyond inheriting the safer
  "do not force Claude channel capability" behavior
- role matching / start-time binary probe unification

## Behavioral invariants

These are the constraints the implementation must preserve:

1. If a client negotiates `experimental.claude/channel`, channel push must keep
   working as it does today.
2. If a client does not negotiate that capability, the server must not drain
   the inbox on the channel path.
3. Messages that arrive before `initialize` completes must not be stranded for
   a capability-positive client.
4. The implementation must not branch on "OAuth vs API key" directly.
5. Claude launch flags that enable channel support where available must remain
   unchanged.
6. The normal fallback path for capability-negative sessions remains:
   inbox retained -> agent hook/plugin/poll drains it.

## Current-state code map

### 1. Managed launcher

File: `ocaml/c2c_start.ml`

Relevant function:

- `build_env`

Current issue:

- exports `C2C_MCP_FORCE_CHANNEL_DELIVERY=1`

Desired change:

- keep `C2C_MCP_CHANNEL_DELIVERY=1`
- remove `C2C_MCP_FORCE_CHANNEL_DELIVERY` from managed startup
- keep Claude dev-channel launch args unchanged

### 2. Runtime capability decision

File: `ocaml/server/c2c_mcp_server.ml`

Relevant functions / state:

- `client_supports_claude_channel`
- `next_channel_capability`
- watcher setup using `channel_capable_ref`
- main request loop handling `initialize`

Current issue:

- `channel_capable_ref` can be seeded from `force_channel_delivery_enabled ()`
- `initialize` capability result is OR-ed with the force flag

Desired change:

- negotiated capability becomes the runtime source of truth
- the server tracks transition from `false -> true`
- once that transition occurs, do one post-initialize catch-up drain

### 3. Push drain primitive

File: `ocaml/c2c_mcp.ml`

Relevant function:

- `Broker.drain_inbox_push`

Reason to use it:

- it already implements the push-path drain semantics
- we only need to control when it is called

## Delivery model after this change

### Capability-positive client

Conditions:

- client sent `initialize` with `capabilities.experimental["claude/channel"]`

Behavior:

1. server replies to `initialize`
2. server performs one catch-up `drain_inbox_push` to flush any mail that
   landed before capability negotiation finished
3. watcher continues to deliver future inbox arrivals via
   `notifications/claude/channel`
4. post-RPC auto-drain behavior remains available for capability-positive
   sessions

### Capability-negative client

Conditions:

- client did not negotiate `experimental.claude/channel`

Behavior:

1. server replies to `initialize`
2. no catch-up push drain runs
3. watcher does not drain
4. post-RPC auto-drain does not drain
5. inbox content remains available for the fallback delivery path

## Implementation sequence

This is intentionally test-first.

### Phase A: tighten the tests around the real contract

#### A1. Launcher env test

File: `ocaml/test/test_c2c_start.ml`

Add coverage for `C2c_start.build_env`:

- assert `C2C_MCP_CHANNEL_DELIVERY=1` is still present
- assert `C2C_MCP_FORCE_CHANNEL_DELIVERY` is absent
- keep the existing Claude launch-arg tests unchanged

Reason:

- this prevents reintroducing force-delivery through the managed launcher

#### A2. Channel integration harness hardening

File: `tests/test_c2c_mcp_channel_integration.py`

Update the helper that spawns the real MCP server:

- explicitly remove inherited `C2C_MCP_FORCE_CHANNEL_DELIVERY` from the test
  environment, or override it to `0`

Reason:

- test outcomes must be driven by negotiated capability, not ambient shell env

#### A3. Capability-positive watcher test

File: `tests/test_c2c_mcp_channel_integration.py`

Update existing watcher-delivery tests so they explicitly call:

- `initialize_server(..., with_channel=True)`

Assertions:

- message written into the inbox is emitted as
  `notifications/claude/channel`
- inbox is drained by the push path

Reason:

- the test should describe the actual contract instead of depending on the old
  force behavior

#### A4. Capability-negative watcher test

File: `tests/test_c2c_mcp_channel_integration.py`

Add a new test:

- start server with watcher enabled
- initialize with `with_channel=False`
- write a message to the inbox
- wait long enough for the watcher to have acted if it were going to
- assert no `notifications/claude/channel` was emitted
- assert the inbox still contains the message

Reason:

- this is the core regression guard for API-key / non-capable sessions

#### A5. Pre-initialize catch-up test

File: `tests/test_c2c_mcp_channel_integration.py`

Add a new test:

- write a message to the inbox before `initialize`
- initialize with `with_channel=True`
- assert the initialize response arrives first
- then assert a single channel notification arrives as catch-up
- then call `poll_inbox` and verify the user message is not returned again

Reason:

- this proves the startup race is closed without requiring a pre-init drain

#### A6. Run focused tests in red state

Commands:

```bash
python3 -m pytest tests/test_c2c_mcp_channel_integration.py -q
opam exec -- dune runtest ocaml/test/test_c2c_start.exe
```

Expected before production changes:

- launcher env test fails because force flag is still exported
- capability-negative / catch-up tests fail because runtime still relies on the
  force path

### Phase B: production changes

#### B1. Stop managed startup from forcing capability

File: `ocaml/c2c_start.ml`

Change:

- remove `("C2C_MCP_FORCE_CHANNEL_DELIVERY", "1")` from `build_env`

Do not change:

- `C2C_MCP_CHANNEL_DELIVERY=1`
- Claude launch args (`--dangerously-load-development-channels`,
  `--channels server:c2c`)

#### B2. Make negotiated capability authoritative

File: `ocaml/server/c2c_mcp_server.ml`

Change:

- initialize `channel_capable_ref` from the negotiated state, not from the
  force env
- stop OR-ing `next_channel_capability` with the force flag in the main loop

Potential implementation shape:

- keep a `channel_capable_ref : bool ref`
- compute `was_capable` before handling each request
- compute `new_capable` from `next_channel_capability`
- after responding to the request, if the method was `initialize` and the state
  transitioned `false -> true`, run catch-up once

#### B3. Add explicit post-initialize catch-up

File: `ocaml/server/c2c_mcp_server.ml`

Behavior:

- only on the `false -> true` transition
- only after the initialize response is flushed
- use `Broker.drain_inbox_push`
- emit one channel notification per returned pushed message, using the same
  notification formatter as the watcher path

Why after the response:

- MCP handshake ordering stays clean
- we do not pretend the client was channel-capable before it told us so

Why one-time:

- closes the startup race only
- ongoing delivery remains handled by the watcher / post-RPC path

#### B4. Preserve fallback semantics for non-capable sessions

Files:

- `ocaml/server/c2c_mcp_server.ml`

Checks:

- watcher remains gated by `channel_capable_ref`
- post-RPC auto-drain remains gated by `channel_capable_ref`
- no other path drains inboxes just because `C2C_MCP_CHANNEL_DELIVERY=1` exists

### Phase C: verification and docs

#### C1. Re-run targeted tests

Commands:

```bash
python3 -m pytest tests/test_c2c_mcp_channel_integration.py -q
opam exec -- dune runtest ocaml/test/test_c2c_start.exe
```

If broader confidence is needed and cheap:

```bash
python3 -m pytest tests/test_c2c_onboarding_smoke.py -q
```

#### C2. Update docs

Likely files:

- `docs/channel-notification-impl.md`
- `docs/MSG_IO_METHODS.md`
- `docs/known-issues.md`

Required doc changes:

- managed Claude startup enables channels where supported, but no longer forces
  channel delivery
- channel push requires negotiated client capability
- fallback delivery remains the correct path for non-capable sessions

#### C3. Leave a clear follow-up marker for the general capability system

Document the next slice:

- shared vocabulary for runtime delivery capabilities
- reuse the same capability names in `c2c start` probes
- align with role `required_capabilities`
- later preference ordering between multiple valid delivery strategies
  (channel push, hook/poll, PTY wake, plugin wake, wire wake)

## Test matrix

Minimum matrix to satisfy before calling this done:

1. Managed launcher env does not export force flag.
2. Claude launch args are unchanged.
3. Capability-positive watcher emits channel notification.
4. Capability-negative watcher does not emit and does not drain.
5. Pre-initialize message is caught up exactly once after capability-positive
   initialize.
6. Existing non-channel tool-path behavior remains intact.

## Risk notes

### Risk: duplicate delivery during startup

Mitigation:

- run catch-up only once on `false -> true`
- verify inbox is empty on later poll in the catch-up test

### Risk: capability-positive behavior regresses for working OAuth sessions

Mitigation:

- keep launch flags unchanged
- preserve watcher and post-RPC push path for negotiated sessions
- keep explicit capability-positive tests

### Risk: hidden env in CI / local shell invalidates tests

Mitigation:

- normalize `C2C_MCP_FORCE_CHANNEL_DELIVERY` inside the Python integration
  harness

## Not part of this patch

These are intentionally deferred:

- removing `force_channel_delivery_enabled` everywhere if another non-managed
  server workflow still uses it as an escape hatch
- building a first-class capability registry type shared across launcher,
  server, role planner, and E2E adapters
- strategy preference logic such as "prefer PTY wake when available even if
  channel push also exists"

## Phase 2 follow-up: source-attributed runtime activity and fallback gating

The next capability-system slice should distinguish:

- static capability: what a client/build/plugin can do in principle
- runtime activity: which delivery source is actually alive for this session

This matters most for OpenCode plugin delivery. Presence of the plugin file is
not enough. We need to know whether the plugin is actively servicing this
instance before deciding to leave the inbox alone or engage a fallback path.

### Statefile model change

The per-instance statefile should track activity by source, not just a single
last-updated timestamp.

Desired shape:

- keep the current overall state payload
- add a source-indexed activity map such as:
  - `plugin`
  - `hook`
  - `wire`
  - `channel`
  - later any other delivery/wake sources we add
- each source entry should record at least:
  - last active timestamp
  - source name / type
  - optional session or instance correlation data where relevant

This lets the broker/launcher answer:

- which source was last active
- whether a given source is stale
- whether fallback should engage yet

### OpenCode plugin liveness contract

For OpenCode, treat the plugin as runtime-active only when:

1. the managed session start time is known
2. the plugin statefile contains a `plugin` activity source
3. that source has been updated after the current managed start
4. that source remains fresh within a bounded staleness window

Initial threshold:

- if the plugin has not refreshed its source activity within 60 seconds of
  managed startup, fallback delivery may engage

This is intentionally a liveness heuristic, not just a static capability bit.

### Plugin heartbeat/no-op updates

The OpenCode plugin should fork an independent lightweight loop early in its
startup path that periodically emits a no-op statefile update:

- interval: every 10 seconds
- effect: update the plugin source's `last_active_at`
- non-effect: do not mutate agent/task/session state beyond source activity

This ensures that:

- plugin liveness remains visible even while the agent is idle
- fallback can key off missed heartbeats instead of guessing from stale files
- we do not need to abuse delivery actions as liveness pings

### Decision rule

The delivery chooser should eventually behave like this for OpenCode:

- plugin active and fresh -> leave inbox alone for plugin delivery
- plugin missing or stale beyond 60 seconds -> fallback path may engage

This keeps the inbox intact when the preferred source is working, while still
providing recovery when the preferred source dies silently.

## Definition of done

This slice is done when all of the following are true:

- the managed launcher no longer exports the force flag
- negotiated channel capability alone controls channel push behavior
- capability-positive sessions preserve today's behavior
- capability-negative sessions keep their inbox intact for fallback delivery
- startup-race messages are caught up once after initialize
- tests and docs reflect the new contract
