# Brainstorm: E2E Harness Extension for Non-Codex Clients

**Date**: 2026-04-23
**Author**: ceo
**Source**: coordinator1 queued slice — extract from todo.txt item 122

## Context

The codex-headless E2E tests (commit 4c9d60c + f2ddb7b) established a capability-gated tmux harness pattern:
1. Spawn two managed client instances via `c2c start <client>`
2. Wait for init + registration
3. Send a DM from one to the other
4. Assert message appears in broker inbox

Existing E2E tests follow the same pattern for OpenCode, Kimi, and (blocked) Claude Code.

**Gap**: The todo item says "capability-gated tmux E2E harness to other first-class clients" — but OpenCode, Kimi, and Claude already have tests. The real gap is specific to the `--agent <name>` flag path:

```
c2c start <client> --agent <name>
```

This means: compile role → launch with role → verify agent file is picked up. None of the current tests exercise the `--agent` path.

## Concrete Takeable Items with ACs

---

### Item 1: Add `--agent` smoke test to OpenCode E2E

**What**: Add a test variant `test_opencode_smoke_with_agent` that:
- Compiles a role via `c2c roles compile --client opencode --dry-run` (or writes directly)
- Launches with `c2c start opencode -n <name> --agent <role>`
- Waits for init + registration
- Verifies the agent file is picked up (check `.opencode/agents/<name>.md` exists)

**AC**:
- [ ] `C2C_TEST_OPENCODE_E2E=1 pytest tests/test_c2c_opencode_e2e.py::test_opencode_smoke_with_agent` passes
- [ ] Role file is generated at `.opencode/agents/<name>.md` before client startup
- [ ] Test is capability-gated (skip if opencode binary absent)

---

### Item 2: Add `--agent` smoke test to Kimi E2E

**What**: Same pattern as OpenCode but for Kimi. Kimi renderer writes to `.kimi/agents/<name>.md`.

**AC**:
- [ ] `C2C_TEST_KIMI_E2E=1 pytest tests/test_c2c_kimi_e2e.py::test_kimi_smoke_with_agent` passes
- [ ] Role file is generated at `.kimi/agents/<name>.md` before client startup
- [ ] Test is capability-gated (skip if kimi binary absent)

---

### Item 3: Unblock Claude E2E (interactive prompts)

**What**: Claude Code startup requires `--yes` flag and possibly `--development-channels=false` to bypass the two interactive TTY prompts (workspace trust + development channels). The current test documents the block in a docstring but doesn't attempt to solve it.

**Research needed**:
- [ ] Find Claude Code non-interactive startup flags (try `--help` or `claude code --help`)
- [ ] Verify `--yes` bypasses workspace trust prompt
- [ ] Verify appropriate flag bypasses development channels prompt
- [ ] Update test to pass these flags via `c2c start claude --auto` or equivalent

**AC**:
- [ ] `C2C_TEST_CLAUDE_E2E=1 pytest tests/test_c2c_claude_e2e.py::test_claude_smoke_send_receive` passes end-to-end without manual TTY intervention
- [ ] Two Claude instances can send DMs to each other via the tmux harness

---

### Item 4: Cross-client `roles compile --client all` smoke test

**What**: A single test that runs `c2c roles compile --client all` and verifies each output file is created for all available clients (opencode, claude, codex, kimi).

**AC**:
- [ ] Test calls `c2c roles compile --client all` in a temp git repo
- [ ] Asserts `.opencode/agents/test.md`, `.claude/agents/test.md`, `.codex/agents/test.md`, `.kimi/agents/test.md` all exist (if respective binary is present)
- [ ] Capability-gated per client (skip file check if binary absent)

---

### Item 5: Shared `compile_role_for_client` helper in framework

**What**: Extract the role-compilation step from individual client tests into a shared helper in `client_adapters.py` or a new `role_utils.py` under `tests/e2e/framework/`.

**AC**:
- [ ] `compile_role(workdir, alias, client)` function exists in framework
- [ ] All client E2E tests use this helper instead of raw `_write_role_file`
- [ ] Helper handles `include:` snippet expansion if present

---

## What NOT to do (out of scope)

- Writing new adapters (all 5 exist)
- Modifying the tmux driver or scenario framework (stable)
- Cross-machine E2E (tracked separately in remote-relay-transport)
- E2E for Crush (not a first-class peer)

## Owner Recommendation

- **Items 1, 2, 5**: Lyra-Quill — DONE (commit 51f162f)
- **Item 3**: Needs Max or galaxy-coder to find Claude Code non-interactive flags
- **Item 4**: Could pair with Item 1 or 2

## Priority Order

1. Item 3 (Claude unblock) — it's the only truly blocked client
2. Item 1 (OpenCode --agent) — OpenCode binary is always available in this environment
3. Item 5 (shared helper) — enables Items 1, 2, 4 cleanly
4. Item 4 (compile --client all) — less urgent, can follow helper
5. Item 2 (Kimi --agent) — depends on Items 1 + 5