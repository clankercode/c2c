# DRAFT: OCaml File Split Plan (#152)

**Status:** DRAFT — not approved for implementation
**Source:** `.collab/reviews/2026-04-24-project-review-codex.md` (#152)
**Goal:** Split oversized OCaml files to reduce LOC, improve separation of concerns, and reduce accidental cross-feature collisions.

## Files Currently Exceeding 2000 LOC

| File | Lines |
|------|------:|
| `ocaml/cli/c2c.ml` | 10,127 |
| `ocaml/relay.ml` | 4,641 |
| `ocaml/c2c_mcp.ml` | 4,225 |
| `ocaml/c2c_start.ml` | 2,877 |

---

## Phase 1: Extract `setup-*` helpers from `c2c.ml`

**Rationale:** Smallest extraction, highest leverage — these helpers have clear boundaries and no cross-cutting dependencies on the main command dispatch.

**Proposed module:** `ocaml/cli/c2c_setup.ml`

**Functions to migrate:**
- `setup_claude_code`, `setup_codex`, `setup_opencode`, `setup_kimi`, `setup_crush`
- Any config-writing helpers that belong to "install and configure a client" concern

**Prerequisite:** Tests around command registration + help/tier visibility before moving code.

---

## Phase 2: Extract command registry/tiering from `c2c.ml`

**Proposed module:** `ocaml/cli/c2c_commands.ml`

**Functions to migrate:**
- `command_tier_map` definition
- `filter_commands`
- `default_kickoff_prompt` (if command-related)
- Help text / doc string definitions

**Note:** This is higher risk — command tiering touches nearly every subcommand.

---

## Phase 3: Extract room/relay/agent-role commands from `c2c.ml`

**Proposed modules:**
- `ocaml/cli/c2c_room.ml` — room subcommands
- `ocaml/cli/c2c_relay.ml` — relay subcommands
- `ocaml/cli/c2c_agent.ml` — agent subcommands (refine, run, new, etc.)
- `ocaml/cli/c2c_plugin.ml` — plugin-sink subcommand

**Note:** These have significant shared state with `c2c_start.ml` (broker root, session management).

---

## Phase 4: Split `relay.ml` (4,641 lines)

**Proposed modules:**
- `ocaml/relay_types.ml` — domain types (message, room, session, etc.)
- `ocaml/relay_store_sqlite.ml` — SQLite persistence
- `ocaml/relay_store_mem.ml` — in-memory store
- `ocaml/relay_http.ml` — HTTP/WS server
- `ocaml/relay_client.ml` — client-side relay logic
- `ocaml/relay_observer.ml` — observer/session handling

---

## Phase 5: Split `c2c_mcp.ml` (4,225 lines)

**Proposed modules:**
- `ocaml/c2c_broker_persist.ml` — broker persistence (registry YAML, inbox, dead-letter)
- `ocaml/c2c_mcp_tools.ml` — tool definitions (MCP tool schemas)
- `ocaml/c2c_mcp_handlers.ml` — tool handlers (handle_request dispatch)
- `ocaml/c2c_session.ml` — session resolution and lifecycle
- `ocaml/c2c_channel.ml` — channel notification logic

---

## Phase 6: Split `c2c_start.ml` (2,877 lines)

**Note:** This file is closer to the limit and more stable — consider deferring until other splits are done.

**Proposed modules:**
- `ocaml/c2c_instance.ml` — instance lifecycle (start, stop, restart)
- `ocaml/c2c_watchdog.ml` — watchdog process management

---

## Execution Rules

1. **One extraction per PR** — each module split is independent, reviewed separately
2. **Test before move** — add tests covering the module's public interface before extracting
3. **Preserve git history** — use `git mv` to keep blame intact
4. **Don't break the build** — `just build` must pass at every PR
5. **Coordinator review** — each PR needs coordinator approval before merge

---

## Open Questions

- [ ] Should `c2c_start.ml` be split before or after `c2c.ml`? (c2c.ml calls c2c_start.ml heavily)
- [ ] Should we add a LOC soft-limit (e.g. 1500) as a CI check to prevent regrowth?
- [ ] Any phase ordering constraints?
