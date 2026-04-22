# Terminal E2E Framework Design

## Problem

This repo already has enough pieces to drive real terminal clients:

- tmux helpers in `scripts/c2c_tmux.py`
- reliable Enter / command-send wrappers in `scripts/c2c-tmux-enter.sh` and
  `scripts/c2c-tmux-exec.sh`
- snapshot capture in `scripts/tui-snapshot.sh`
- process-leak and subprocess hygiene in `tests/conftest.py`
- credible live OpenCode tests in `tests/test_c2c_opencode_tmux.py` and
  `tests/test_c2c_opencode_twin_e2e.py`

What it does not have is a single reusable end-to-end testing framework for
terminal clients. Today the repo has:

- scattered tmux helpers
- repeated `_tmux(...)`, capture, wait, and cleanup logic across tests
- client-specific harnesses that do not share one authoring model
- no common abstraction for `tmux` vs fake PTY backends

That is becoming a real problem for Codex and `codex-headless` work. We need:

- live tests for `c2c start codex`
- live tests for `c2c start codex-headless`
- explicit pass-now / xfail-now capability gates for updated Codex binaries
- a reusable way to describe terminal scenarios simply in code

The goal is not just “one Codex smoke test.” The goal is a small but real
terminal E2E framework that makes future client testing cheaper.

## Goal

Add a reusable `pytest`-owned terminal E2E framework that:

- exposes a simple Python scenario API for live terminal tests
- uses one shared `TerminalDriver` interface across `tmux` and fake PTY
  backends
- separates terminal mechanics from client-specific readiness and assertions
- collects useful per-test artifacts automatically
- ships first with Codex and `codex-headless` coverage

The first cut must be good enough to author tests like:

```python
def test_codex_auto_discovers_peer(scenario):
    a = scenario.start_agent("codex", name="test-codex-1", auto=True)
    b = scenario.start_agent("codex", name="test-codex-2", auto=True)

    scenario.wait_for_init(a, b)
    scenario.comment("Agents should discover each other without intervention")

    scenario.sleep(30)

    scenario.assert_agent(a).sent_messages_gt(2)
    scenario.assert_agent(b).sent_messages_gt(2)
```

This remains ordinary Python under `pytest`. The Python API is the DSL.

## Non-Goals

- replacing `pytest` with a custom test runner
- introducing a YAML or markdown scenario parser in v1
- migrating every existing tmux/live test immediately
- making fake PTY prove full correctness of real Codex/OpenCode/Claude sessions
  in v1
- replacing the existing tmux scripts instead of reusing them
- building a large snapshot-diffing platform before the framework proves itself

## Recommended Approach

Use a Python scenario object layered over a shared `TerminalDriver` interface.

Why this approach:

- it fits the repo’s strongest existing primitives
- it keeps tests readable without adding a parser
- it works naturally with `pytest` skips, `xfail`, fixtures, and artifact hooks
- it leaves room for later fake-PTY and lower-cost model configurations without
  changing the authoring surface

Alternative shapes were considered:

- fixture-heavy helpers only: too procedural for multi-agent live scenarios
- custom step interpreter / parser: too much framework weight for v1

## Architecture

The framework should have four layers.

### 1. `Scenario`

`Scenario` is the author-facing orchestration object used directly in tests.

Responsibilities:

- launch agents
- track scenario comments and timeline
- wait for readiness
- broker-level send and verification helpers
- capture artifacts automatically on failure
- expose a readable assertion surface

`Scenario` owns orchestration. It should not know how to talk to tmux directly
or how to interpret a specific client’s state files.

### 2. `TerminalDriver`

`TerminalDriver` is the mechanical terminal abstraction.

Responsibilities:

- launch terminal/session
- send literal text
- send submit / keypresses
- capture current terminal text
- report liveness / exit status
- stop / cleanup

It should not contain client-specific readiness logic.

Rough interface:

```python
class TerminalDriver:
    def start(self, spec) -> TerminalHandle: ...
    def send_text(self, handle, text: str) -> None: ...
    def send_key(self, handle, key: str) -> None: ...
    def capture(self, handle) -> TerminalCapture: ...
    def is_alive(self, handle) -> bool: ...
    def stop(self, handle) -> None: ...
```

Concrete backends for v1:

- `TmuxDriver`
- `FakePtyDriver`

### 3. `ClientAdapter`

`ClientAdapter` owns client-specific behavior.

Responsibilities:

- build `c2c start <client> ...` launch commands
- define readiness conditions
- expose client-specific observation logic
- provide capability probes

Examples:

- `CodexAdapter`
- `CodexHeadlessAdapter`
- later `OpenCodeAdapter`
- later `ClaudeAdapter`

This keeps client quirks out of the generic driver.

### 4. `ArtifactCollector`

Each scenario should write artifacts under:

```text
.artifacts/e2e/<test-name>/<run-id>/
```

Always collect:

- event trace / timeline
- terminal captures and snapshots
- broker snapshot
- managed instance state
- relevant stderr / client logs

Optional:

- golden snapshot comparisons for stable surfaces

Golden comparisons should be opt-in and limited to intentionally stable
terminal surfaces. They should not be required for noisy live-agent transcript
flows.

## Authoring API

Tests stay as normal `pytest` functions.

Core scenario methods:

- `start_agent(client, name=..., auto=False, backend=..., model=..., extra_args=..., env=...)`
- `wait_for_init(*agents, timeout=...)`
- `wait_for(predicate, timeout=..., interval=...)`
- `sleep(seconds)`
- `comment(text)`
- `send_dm(from_agent, to_agent, text)`
- `capture(agent)`
- `snapshot(agent, golden=...)`
- `stop(agent)`
- `restart(agent)`
- `assert_agent(agent)`

### Cost Control

`start_agent(...)` must support cost-control launch knobs from the start.

That includes:

- model selection
- per-client env overrides
- extra launch arguments needed to choose cheaper test configurations

This is required so later fake-PTY or live-client runs can target specific
models without redesigning the API.

### Assertions

`assert_agent(agent)` should provide a fluent assertion surface for common
scenario checks, such as:

- messages sent / received
- process still alive
- broker registration alive
- expected text visible in terminal capture

The exact assertion catalog can remain small in v1 and grow based on real test
usage.

## Readiness Model

`wait_for_init(...)` should use layered readiness.

Baseline requirements:

- terminal process/session is alive
- managed `c2c` state exists
- broker registration is alive

If a client has a stronger readiness signal, its adapter may require it too.

Examples:

- `CodexAdapter`
  - TUI or managed process has started
  - broker registration is alive
  - no immediate crash/exit
- `CodexHeadlessAdapter`
  - bridge process is alive
  - required handoff state is present when applicable
- `OpenCodeAdapter`
  - adopted root session / statefile is present
- `FakePtyDriver`
  - fake terminal started and attached

The driver reports mechanics. The adapter defines what “ready” means for the
client.

## Capability Gating

Capability gating should remain native Python, not hidden in stringly test
metadata.

Examples:

- `scenario.require_binary("codex")`
- `scenario.require_capability("codex_xml_fd")`
- `scenario.xfail_unless("codex_xml_fd", reason="updated Codex binary not installed")`

This is especially important for Codex work:

- stock Codex fallback tests should pass now
- XML sideband TUI tests should be explicit `xfail` until the updated Codex
  binary advertises `--xml-input-fd`
- `codex-headless` tests should gate on bridge capabilities such as
  `--thread-id-fd`

Silent skip is the wrong behavior for expected-but-not-yet-landed capabilities.

## Backend Design

### `TmuxDriver`

`TmuxDriver` is the primary live backend in v1.

It should reuse existing repo primitives instead of replacing them:

- `scripts/c2c_tmux.py`
- `scripts/c2c-tmux-enter.sh`
- `scripts/c2c-tmux-exec.sh`
- `scripts/tui-snapshot.sh`

It should support:

- creating sessions/panes
- launching `c2c start ...`
- sending text and keys safely
- terminal capture
- deterministic cleanup

### `FakePtyDriver`

`FakePtyDriver` should ship in v1 but stay smaller.

V1 responsibilities:

- validate the shared driver API
- support lower-cost harness/protocol tests
- provide a path toward fuller fake-PTY client launches later

V1 does **not** need to prove full real-client correctness for Codex, Claude,
or OpenCode. But it must be designed so those clients can later run through it
with explicit model/config overrides.

## Reuse Strategy

This framework should extend existing patterns, not replace them.

Extend:

- `tests/conftest.py` for shared cleanup and process hygiene
- `scripts/c2c_tmux.py` for tmux orchestration
- `scripts/c2c-tmux-enter.sh` and `scripts/c2c-tmux-exec.sh` as canonical
  submit/send primitives
- `scripts/tui-snapshot.sh` as the authoritative snapshot pattern
- existing OpenCode harness patterns for readiness and visible delivery

Avoid:

- writing a second tmux abstraction beside the one already in the repo
- scattering more copy-pasted `_tmux(...)` wrappers across new test files

## Initial File Plan

Initial framework files:

- `tests/e2e/framework/scenario.py`
- `tests/e2e/framework/terminal_driver.py`
- `tests/e2e/framework/tmux_driver.py`
- `tests/e2e/framework/fake_pty_driver.py`
- `tests/e2e/framework/client_adapters.py`
- `tests/e2e/framework/artifacts.py`

These names are intentionally plain. If one file grows too large, split by
responsibility later rather than up front.

## First Tests To Build

### 1. `tests/test_c2c_codex_twin_e2e.py`

This should be the first real consumer.

Scenarios:

- stock Codex fallback smoke
- Codex XML-path test with explicit `xfail` until the updated binary arrives

### 2. `tests/test_c2c_codex_headless_e2e.py`

Scenarios:

- bridge capability smoke
- `xfail` gate for missing required bridge surfaces

### 3. Framework self-tests

Add one framework-focused test file proving:

- the same scenario API works with `TmuxDriver`
- the same scenario API works with `FakePtyDriver`

These should be CI-safe and narrower than the live Codex tests.

## Execution Policy

- live tmux tests are opt-in via env flags and required binaries
- capability-gated Codex XML tests use explicit `xfail`, not silent skip
- framework self-tests and narrow fake-PTY tests should remain routine CI-safe

This keeps the suite honest without making baseline CI permanently red.

## Rollout Strategy

The framework should be built around Codex and `codex-headless` first, because
that is the current unblocker.

Migration order:

1. build the framework
2. land Codex/Codex-headless early-eval coverage on top of it
3. once the API feels stable, port the next best-fit live test

The likely next migration target is OpenCode, because it already has the
strongest live tmux/E2E coverage and can help retire parallel styles.

## Risks

- tmux and fake PTY may drift unless the shared `TerminalDriver` contract stays
  narrow
- readiness can become flaky if client adapters overfit transient UI text
- snapshot comparisons can become noisy if applied too broadly
- live-agent tests can burn cost if model/config control is not part of the API
  from the start

The mitigation is to keep v1 small, capability-aware, and anchored to existing
repo primitives.

## Success Criteria

This design is successful when:

- a Codex twin E2E test can be expressed through the scenario API without
  bespoke tmux glue
- `codex` fallback behavior is live-testable now
- Codex XML/TUI behavior is represented as an explicit `xfail` gate until the
  updated binary arrives
- `codex-headless` capability gating is live-testable through the same API
- the repo has one credible terminal E2E backbone rather than more one-off
  smoke tests
