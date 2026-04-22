# Codex `c2c start` Comprehensive Testing Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add comprehensive, programmatic test coverage for `c2c start codex`, including current fallback behavior and the future XML sideband path expected from the updated Codex binary.

**Architecture:** Extend the existing testing strategy in layers. Keep fast unit/CLI tests around launch-arg selection and daemon wiring, then add opt-in tmux E2E tests that exercise real managed Codex sessions in fresh git repos. Split expectations into two tracks: tests that must pass on today’s stock/fallback Codex, and tests that are expected to fail or xfail until the new Codex binary exposes the XML/TUI delivery surface.

**Tech Stack:** Python `pytest`/`unittest`, tmux-driven integration tests, real `c2c` CLI binary, real `codex` CLI, broker files under git-common-dir, existing `c2c_deliver_inbox.py` XML/PTY support.

---

## Scope

This plan covers **testing only**. It does not change Codex delivery behavior itself.

Primary target:
- managed `c2c start codex`

Must cover:
- launch and registration
- fallback notify path on stock Codex
- future XML sideband path on updated Codex
- DM delivery
- cross-peer behavior
- resume/restart behavior
- cleanup / no orphan outer loops

Must explicitly model:
- **pre-new-binary world:** some XML-user-turn tests are expected to fail or xfail
- **post-new-binary world:** the same tests become the acceptance gate

## Current Code And Test Surface

Relevant existing files:
- `tests/test_c2c_opencode_twin_e2e.py`
  - best model for a real two-agent tmux E2E using `c2c start ... --auto`
- `tests/test_c2c_opencode_tmux.py`
  - example of tmux-visible operator debugging style
- `tests/test_c2c_start.py`
  - current OCaml CLI coverage, including Codex XML fd launch-arg and deliver-daemon wiring
- `tests/test_c2c_deliver_inbox.py`
  - existing Codex XML spool / write tests for the Python daemon
- `ocaml/c2c_start.ml`
  - Codex capability probe, `--xml-input-fd` insertion, child-side FD plumbing, daemon start
- `docs/client-delivery.md`
  - expected user-visible Codex behavior for XML sideband and PTY fallback
- `docs/x-codex-client-changes.md`
  - branch-level explanation of XML/TUI behavior expected from the updated Codex binary

## Test Matrix

### Layer 1: Fast Deterministic Tests

These should run in routine CI and stay green regardless of whether the new Codex binary is installed.

Coverage:
- `c2c start codex` launch-arg selection
- `--xml-input-fd` capability detection behavior
- deliver-daemon argv selection
- managed instance metadata / cleanup
- broker-side spool semantics already covered by `tests/test_c2c_deliver_inbox.py`

These mostly exist already, but need a small Codex-specific expansion for resume and capability branching.

### Layer 2: Stock Codex tmux E2E

These use a real `codex` binary in tmux and verify the **fallback path**:
- managed launch succeeds
- broker registration is alive under requested alias
- PTY notify path runs
- broker DM reaches inbox
- session remains operable
- outer process exits when inner exits
- relaunch resumes the same managed identity

These should pass **before** the new Codex binary arrives.

### Layer 3: Updated Codex tmux E2E (XML/TUI path)

These use the updated Codex binary and verify the **preferred path**:
- `codex --help` advertises `--xml-input-fd`
- `c2c start codex` launches with sideband fd
- daemon writes XML frames
- inbound c2c message appears as a real user turn in the Codex TUI/session
- same-thread resume behavior preserves context and delivery still works

These are expected to fail or xfail until the updated Codex binary is present.

### Layer 4: Cross-Client Parity E2E

Once Layer 3 is in place, add a mixed-client test:
- Codex ↔ OpenCode
- optionally Codex ↔ Claude later if Claude’s wake path is stable enough for E2E

This verifies that Codex is a first-class peer, not just a self-contained local harness.

## Expected Failure Policy

The tests must not create “red all the time” noise in normal CI. Use explicit capability gating.

Rules:
- Stock/fallback Codex tests must pass with any supported Codex binary.
- XML sideband tests must:
  - detect `--xml-input-fd` via `codex --help`
  - `pytest.xfail(...)` with a precise reason when unsupported
  - become hard assertions once the updated binary is installed in the test environment

Do **not** silently skip XML tests.
Use xfail with a message like:
- `"updated Codex binary with --xml-input-fd not present yet"`

That keeps the missing capability visible while preserving a meaningful signal.

## File Plan

### Create: `tests/test_c2c_codex_twin_e2e.py`

Responsibility:
- real tmux E2E for two managed Codex peers
- fallback behavior first
- XML path coverage second, gated by runtime capability probe

Key scenarios in this file:
- `test_codex_twin_e2e_fallback_notify_path`
- `test_codex_twin_e2e_resume_same_alias`
- `test_codex_twin_e2e_xml_user_turn_delivery` (xfail until new binary)
- `test_codex_twin_e2e_cross_send_between_two_codex_peers`

### Modify: `tests/test_c2c_start.py`

Responsibility:
- fill remaining Codex unit/CLI gaps

Add coverage for:
- no `--xml-input-fd` → notify-only daemon selected
- yes `--xml-input-fd` → XML daemon selected
- Codex relaunch uses existing `resume --last` model under managed sessions
- Codex child/outer cleanup behavior mirrors OpenCode expectations

### Modify: `tests/test_c2c_deliver_inbox.py`

Responsibility:
- keep daemon-side XML guarantees aligned with what tmux E2E will expect

Add or tighten:
- multi-message XML delivery order
- XML body contains literal inner `<c2c ...>` envelope
- spool survives daemon restart / second once-call round

### Create: `tests/helpers/codex_tmux.py`

Responsibility:
- shared tmux helpers for Codex E2E tests so the test file stays readable

Helpers:
- create/kill session
- capture pane text
- wait loops
- probe Codex capability
- read managed instance files
- inspect broker registry / inbox

If that feels too small to justify a helper file, keep helpers inline in the test file. Do not split prematurely.

### Optional Create Later: `tests/test_c2c_codex_cross_client_e2e.py`

Responsibility:
- mixed Codex/OpenCode live E2E after the pure Codex file is stable

Keep this out of v1 unless the main Codex twin E2E is already reliable.

## Detailed Test Scenarios

### Scenario A: Stock Codex managed launch works

Purpose:
- prove `c2c start codex` can launch a real Codex TUI in tmux and register under the requested alias

Assertions:
- registration appears in broker with alias = requested name
- registration is alive
- per-instance dir exists
- outer prints resume guidance on exit
- no unexpected backgrounding/orphan loop

### Scenario B: Fallback delivery nudges polling path

Purpose:
- prove stock Codex still gets usable c2c delivery without XML support

Assertions:
- send DM to Codex alias
- inbox file receives message
- notify path is active
- Codex pane or managed logs show the fallback nudge / poll instruction
- message remains retrievable with `c2c poll-inbox`

Important:
- do **not** require “real user turn” semantics in this scenario
- that belongs only to the new XML path

### Scenario C: Managed exit tears down cleanly

Purpose:
- catch outer-loop regressions and stale instance state

Assertions:
- exit Codex from the tmux pane
- broker alive status drops
- `fg` in the shell shows no jobs / no suspended outer process
- no lingering workdir-anchored Codex or deliver-daemon processes remain

### Scenario D: Relaunch resumes managed Codex session identity

Purpose:
- ensure restart behavior is stable enough for real use

Assertions:
- stop/relaunch same alias
- broker identity remains same alias
- instance dir reused
- Codex launch shape still reflects resume mode
- post-relaunch DM delivery still works

Note:
- Codex currently uses `resume --last`, not an explicit thread id
- the test should verify observable managed behavior, not overfit internal CLI strings unless those are already persisted in state

### Scenario E: Updated Codex XML path activates

Purpose:
- prove the new binary actually switches the harness to sideband XML delivery

Precondition:
- `codex --help` contains `--xml-input-fd`

Assertions:
- launch args include `--xml-input-fd`
- deliver daemon is started without `--notify-only`
- XML spool path `codex-xml/<session>.spool.json` is used
- sending a DM causes XML spool/drain activity

### Scenario F: Updated Codex receives a real user turn

Purpose:
- the main acceptance criterion for the new Codex support

Precondition:
- same as Scenario E

Assertions:
- send DM to managed Codex
- Codex transcript/TUI visibly includes the DM as a user turn, not just a wake nudge
- the visible content contains the inner `<c2c ...>` envelope or rendered user message content, depending on what the updated TUI shows
- no manual `poll_inbox` is required

Implementation note:
- this test must tolerate some TUI rendering variation
- prefer checking for a stable substring from the DM body plus evidence that the message landed in transcript context, not only raw ANSI screen shape

### Scenario G: Two Codex peers can message each other

Purpose:
- validate Codex as a peer, not only as a recipient from the harness

Assertions:
- launch two Codex panes
- send harness DM to each to establish liveness
- cause peer A to send to peer B using MCP or CLI inside the managed session if possible
- confirm peer B receives it through the active delivery path

This can be phase 2 if direct in-TUI scripting is initially flaky.

## Implementation Strategy

### Task 1: Codex tmux test skeleton

**Files:**
- Create: `tests/test_c2c_codex_twin_e2e.py`

- [ ] **Step 1: Write the failing gated test skeleton**

Create a new pytest file modeled on `tests/test_c2c_opencode_twin_e2e.py` with:
- tmux session fixture
- environment gate `C2C_TEST_CODEX_TWIN_E2E=1`
- binary presence checks for `tmux`, `codex`, `c2c`
- helper to detect `--xml-input-fd` support

- [ ] **Step 2: Run test to verify gate behavior**

Run: `python3 -m pytest tests/test_c2c_codex_twin_e2e.py -q --force-test-env`

Expected:
- skipped unless `C2C_TEST_CODEX_TWIN_E2E=1`

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): add tmux e2e skeleton"
```

### Task 2: Fallback launch and cleanup E2E

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`

- [ ] **Step 1: Write the failing fallback launch test**

Add:
- fresh tmp git repo
- `c2c install codex` setup if required for managed MCP config
- two tmux panes
- `c2c start codex -n <alias>` launches
- broker alive assertions
- teardown / no-orphan assertions

- [ ] **Step 2: Run the focused test**

Run:
`C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k fallback -v --force-test-env`

Expected before XML binary:
- PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): cover fallback managed launch and cleanup"
```

### Task 3: Fallback notify delivery E2E

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`
- Modify: `tests/test_c2c_deliver_inbox.py`

- [ ] **Step 1: Write failing delivery assertions**

Add a test that:
- sends a harness DM to managed Codex
- verifies inbox message appears
- verifies fallback notify path/log evidence
- verifies `poll-inbox` can still drain the message

- [ ] **Step 2: Tighten daemon-side unit coverage if needed**

If the tmux test needs stronger daemon guarantees, add focused unit coverage in `tests/test_c2c_deliver_inbox.py` first.

- [ ] **Step 3: Run focused tests**

Run:
- `python3 -m pytest tests/test_c2c_deliver_inbox.py -k codex -v --force-test-env`
- `C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k notify -v --force-test-env`

Expected before XML binary:
- PASS

- [ ] **Step 4: Commit**

```bash
git add tests/test_c2c_codex_twin_e2e.py tests/test_c2c_deliver_inbox.py
git commit -m "test(codex): verify fallback notify delivery"
```

### Task 4: Resume E2E

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`
- Modify: `tests/test_c2c_start.py`

- [ ] **Step 1: Write failing resume tests**

Add:
- tmux E2E for exit + relaunch same alias
- CLI/unit assertions in `tests/test_c2c_start.py` around Codex resume selection and daemon selection

- [ ] **Step 2: Run focused tests**

Run:
- `python3 -m unittest tests.test_c2c_start -v`
- `C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k resume -v --force-test-env`

Expected before XML binary:
- PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_start.py tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): cover managed resume behavior"
```

### Task 5: XML capability-gated E2E

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`
- Modify: `tests/test_c2c_start.py`

- [ ] **Step 1: Write failing XML-sideband tests**

Add:
- capability probe helper: `codex --help` contains `--xml-input-fd`
- xfail if absent
- if present, assert XML launch path, XML daemon, XML spool usage

- [ ] **Step 2: Run focused tests**

Run:
- `python3 -m unittest tests.test_c2c_start -v`
- `C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k xml -v --force-test-env`

Expected before updated binary:
- XFAIL with clear reason

Expected after updated binary:
- PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_start.py tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): add xml sideband capability gating"
```

### Task 6: Real user-turn delivery acceptance test

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`

- [ ] **Step 1: Write the failing transcript-visible XML delivery test**

Add a test that sends a DM and asserts it shows up as a real user turn in Codex when XML is supported.

- [ ] **Step 2: Run focused test**

Run:
`C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k user_turn -v --force-test-env`

Expected before updated binary:
- XFAIL

Expected after updated binary:
- PASS

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): verify xml user-turn delivery"
```

### Task 7: Cross-Codex peer messaging

**Files:**
- Modify: `tests/test_c2c_codex_twin_e2e.py`

- [ ] **Step 1: Write failing two-peer message exchange test**

Add:
- two managed Codex peers
- confirm each can receive harness DMs
- then verify at least one peer-to-peer send path and receive path

- [ ] **Step 2: Run focused test**

Run:
`C2C_TEST_CODEX_TWIN_E2E=1 python3 -m pytest tests/test_c2c_codex_twin_e2e.py -k peer -v --force-test-env`

Expected before updated binary:
- fallback subcases may pass
- XML-specific peer delivery can xfail if it depends on the new binary

- [ ] **Step 3: Commit**

```bash
git add tests/test_c2c_codex_twin_e2e.py
git commit -m "test(codex): cover two-peer exchange"
```

## Acceptance Criteria

### Must pass now

- Codex launch/cleanup/resume fast tests
- stock Codex tmux fallback launch test
- stock Codex fallback notify delivery test
- no-orphan cleanup assertions

### Must xfail now, pass later

- XML sideband activation
- real user-turn inbound delivery
- any assertion that depends specifically on the updated Codex TUI XML behavior

### Must pass once the new Codex binary is available

- all XML capability-gated tests
- end-to-end inbound DM as transcript-visible user turn
- resume + continued XML delivery

## Risks And Mitigations

- **Risk:** Codex TUI output is hard to assert from tmux capture.
  - Mitigation: assert on multiple signals: broker files, instance files, spool files, deliver logs, and pane text.

- **Risk:** XML tests become flaky because of timing around delivery.
  - Mitigation: use `_wait_for(...)` loops with stable broker/log signals before pane-text assertions.

- **Risk:** Fallback and XML tests interfere if run against different Codex builds on one machine.
  - Mitigation: detect capability at runtime per test session and branch expectations explicitly.

- **Risk:** Tests accidentally encode current implementation internals too tightly.
  - Mitigation: assert external behavior first, then only the minimum internal signals needed for diagnosis.

## Recommended Order

1. Fast Codex `test_c2c_start.py` expansions
2. Stock Codex fallback tmux E2E
3. Resume/cleanup tmux E2E
4. XML capability gating
5. XML real-user-turn acceptance
6. Optional cross-client parity E2E

## Self-Review

Spec coverage:
- Similar to existing OpenCode tmux testing: yes
- More comprehensive than current coverage: yes, includes fallback + XML + resume + cleanup + parity
- Programmatic verification of Codex support from c2c: yes
- Expected failures before updated binary arrives: explicitly modeled with xfail

Placeholder scan:
- No `TODO`/`TBD`
- Concrete files and commands included
- Each task has explicit expected outcomes

Type/interface consistency:
- Uses current Codex launch model from `ocaml/c2c_start.ml`
- Uses current XML capability name `--xml-input-fd`
- Uses current daemon behavior from `docs/client-delivery.md`

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-22-codex-start-comprehensive-testing.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
