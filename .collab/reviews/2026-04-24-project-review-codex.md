# Project Review: c2c

Date: 2026-04-24T10:24:12Z  
Reviewer: Codex  
Scope: current working tree in `/home/xertrov/src/c2c`, with pre-existing local/untracked changes left untouched.

## Executive Summary

c2c is moving in the right direction: the north-star shape is visible, the OCaml path is clearly the current source of truth, and the repo has unusually strong dogfooding infrastructure for a young multi-agent system. The main risks are not lack of intent or test coverage; they are source-of-truth drift, oversized OCaml modules, and a broken Python test collection path caused by migration leftovers.

Recommended team focus:

1. Fix the Python test collection break or explicitly retire those tests.
2. Split the large OCaml files along existing boundaries before adding more behavior.
3. Update onboarding docs so new agents land on the OCaml CLI/MCP reality, not the old Claude-to-Claude PTY experiment.
4. Make `c2c doctor` output more actionable for the swarm's actual operating state.

## Findings

### Critical: `just test-py` fails during collection

Evidence:

- Command: `just test-py`
- Result: exit code 2 during pytest collection.
- Missing imports include `c2c_inject`, `c2c_kimi_wake_daemon`, `c2c_opencode_wake_daemon`, `c2c_relay_gc`, and `c2c_relay_sqlite`.
- Those modules now exist under `deprecated/`, not at repo root.
- `c2c_cli.py:17` still imports `c2c_inject` directly.
- `tests/test_c2c_cli_dispatch.py:16` imports `c2c_cli`, so one missing legacy import cascades into multiple collection failures.

Impact:

- Full `just test` cannot be trusted until Python collection is restored or intentionally narrowed.
- Migration state is ambiguous: some files are "deprecated", but tests and the legacy dispatcher still treat them as importable production modules.
- New agents will waste time chasing phantom dependency/setup issues.

Suggested fix:

- Pick one policy and encode it:
  - Restore thin root-level compatibility shims that import from `deprecated.*`.
  - Or update `c2c_cli.py` and affected tests to import from `deprecated`.
  - Or remove/skip legacy tests when the corresponding CLI path is intentionally retired.
- Add a short migration invariant: deprecated modules cannot be moved unless test collection still passes.

### Critical: OCaml production files exceed the 2,000 LOC hard limit

Evidence from `wc -l`:

| File | Lines | Notes |
|---|---:|---|
| `ocaml/cli/c2c.ml` | 10,127 | CLI router, installers, lifecycle, rooms, relay, role tooling, plugin sinks, statefile/debug tooling |
| `ocaml/relay.ml` | 4,641 | relay domain types, in-memory store, SQLite store, observer sessions, server, client |
| `ocaml/c2c_mcp.ml` | 4,225 | MCP schema, broker persistence, session derivation, auto-register/join, tool dispatch |
| `ocaml/c2c_start.ml` | 2,877 | managed-instance orchestration across clients |

Impact:

- These files are now integration hubs rather than modules.
- Changes to one feature can accidentally affect unrelated paths.
- Reviewers cannot cheaply reason about behavior, which is dangerous for auth, relay, delivery, and process lifecycle code.

Suggested split order:

1. Split `ocaml/cli/c2c.ml` first because it is the highest fan-in file.
2. Extract install/setup code around `setup_codex`, `setup_kimi`, `setup_opencode`, `setup_claude`, and `setup_crush` into a CLI setup module.
3. Extract command tiering/help into a CLI command registry module.
4. Extract room commands, relay commands, agent/role commands, and plugin sink commands into separate modules.
5. Split `ocaml/relay.ml` into relay domain, SQLite store, in-memory store, HTTP/WebSocket server, observer/session handling, and client.
6. Split `ocaml/c2c_mcp.ml` into broker persistence, tool definitions, tool handlers, session resolution, and channel notification.

### Important: Documentation and migration state disagree with the code

Evidence:

- `README.md` still describes "Claude-to-Claude messaging experiments" and highlights `claude-list-sessions`, `claude-send-msg`, and `claude-read-history` as the validated commands.
- `MIGRATION_STATUS.md` says `c2c_inject.py`, wake daemons, `c2c_relay_gc.py`, and `c2c_relay_sqlite.py` are still needed, but these files are now under `deprecated/`.
- The repo instructions say OCaml is the source of truth.
- `docs/client-delivery.md` is much closer to current reality and should probably inform the README.

Impact:

- New agents are likely to start from the wrong mental model.
- The same module can be simultaneously "deprecated", "still needed", and imported by tests.
- This directly contributed to the Python test collection break above.

Suggested fix:

- Make README point to current OCaml CLI/MCP workflows first.
- Move the old PTY Claude material into a clearly labeled historical section.
- Update `MIGRATION_STATUS.md` so every moved module has one of: active root module, deprecated with shim, deprecated with skipped tests, or deleted.

### Important: `c2c doctor` shows the swarm/broker state is noisy

Evidence:

- `c2c health` reported `registrations: 23 (0 alive, 16 unknown, 7 dead)`.
- `c2c health` reported `relay: error response from https://relay.c2c.im`.
- `c2c doctor` listed a very large number of stopped managed instances.
- `c2c doctor` concluded `No push needed`, and all four queued commits were classified local-only.

Impact:

- Health output mixes useful findings with a lot of stale operational state.
- If agents treat this as normal background noise, real delivery regressions become harder to notice.
- The relay error may be benign for local-only work, but it is still a red flag against the north-star remote/delivery surface.

Suggested fix:

- Add a focused "operator action" section to `c2c doctor`: what is safe to ignore, what needs coordinator review, and what should be fixed now.
- Keep respecting the no-sweep-during-active-swarm rule, but provide a safe cleanup workflow for stopped instance metadata.
- Separate local-only health from remote relay health so a local pass does not hide relay breakage.

### Important: command tiering is carrying misleading subcommand metadata

Evidence:

- `ocaml/cli/c2c.ml` has top-level command tier entries like `rooms`, plus apparent subcommand entries like `rooms-send`, `rooms-join`, `room-send`, and `room-join`.
- The actual filter in `filter_commands` only checks `Cmdliner.Cmd.name` for the top-level command being filtered.
- Repo instructions explicitly warn that tier filtering is top-level only.

Impact:

- The tier table looks more precise than enforcement actually is.
- Agents editing a subcommand tier can believe they changed behavior when they only changed documentation-like metadata.
- This is particularly risky for lifecycle/system commands because visibility and safety are part of the UX contract.

Suggested fix:

- Either remove inert per-subcommand tier entries or convert the table into explicit documentation with comments saying they do not affect filtering.
- If per-subcommand enforcement is desired, add a real command-tree filter and tests.

### Minor: source duplication is already visible across setup and identity helpers

Evidence:

- `ocaml/cli/c2c.ml` defines `alias_words` and setup alias generation.
- `ocaml/c2c_start.ml` also defines client alias generation helpers.
- Several modules have local JSON write and mkdir helpers.

Impact:

- Small behavior drift will keep appearing, especially in install/start/session identity paths.
- This makes cross-client parity harder than it needs to be.

Suggested fix:

- Extract shared alias generation, JSON atomic write helpers, and mkdir helpers into small modules.
- Add parity tests for install/start identity values across Claude, Codex, OpenCode, Kimi, and Crush.

## What Looks Strong

- The north-star is present in code and docs: rooms, DMs, auto-join, managed sessions, and per-client delivery are all represented.
- The OCaml test suite passed in this review run via `just test-ocaml`.
- The OpenCode plugin test suite passed via `just test-ts`: 36 passed, 2 skipped.
- `just check` passed.
- The MCP broker writes JSON atomically in `ocaml/c2c_mcp.ml`, which is exactly the kind of filesystem hygiene this project needs.
- `tests/conftest.py` has process-leak protection, which is very appropriate for this repo's live-agent testing style.
- The `justfile` is a good operational front door and should remain the blessed interface.

## Verification Run

Commands run:

| Command | Result |
|---|---|
| `mcp__c2c__poll_inbox` | empty inbox |
| `git status --short` | pre-existing dirty/untracked files present |
| `just check` | passed |
| `just test-ocaml` | passed |
| `just test-ts` | passed: 36 passed, 2 skipped |
| `just test-py` | failed during collection with 8 import errors |
| `c2c health` | broker exists, 0 alive registrations, relay error |
| `c2c doctor` | no push needed; many stopped instances listed |

## Proposed Next Slice

Best immediate slice:

1. Fix `just test-py` collection by resolving the deprecated-module import policy.
2. Commit that as a narrow test-health fix.
3. Then start an OCaml CLI extraction plan with tests around command registration and help/tier visibility before moving code.

This gives the team a clean test floor before doing the larger structural work.
