# OCaml Migration Assessment

Generated: 2026-04-17T13:03:24Z
Author: Codex

## Executive Summary

The OCaml migration has crossed the important threshold: the current primary
broker and user-facing `c2c` command are now OCaml-owned, and `just install`
installs OCaml binaries rather than Python wrappers. The MCP broker, local
file-backed messaging model, rooms, dead-letter behavior, liveness, health,
setup, managed start/stop, and a broad CLI are present in OCaml.

The migration is not finished. Python still owns or significantly supports
several operational surfaces: remote relay connector/status/config/rooms/gc,
SQLite relay storage, wake/delivery daemons, Kimi wire bridge, legacy wrapper
installation, older per-command wrappers, and many tests. Documentation is
split between current OCaml architecture docs and stale README/legacy command
lists that still make the Python wrapper world look canonical.

Recommended direction: treat OCaml as the current product surface and keep
Python as an explicitly named compatibility/support layer until each remaining
surface is either ported, retired, or isolated behind `c2c legacy ...`.

## Evidence Gathered

Commands run:

- `find ocaml -maxdepth 3 -type f | sort`
- `find . -maxdepth 1 -type f -name '*.py' | sort`
- `rg` searches across `justfile`, docs, tests, and OCaml sources
- `_build/default/ocaml/cli/c2c.exe --help`
- `_build/default/ocaml/cli/c2c.exe --version`
- `_build/default/ocaml/cli/c2c.exe smoke-test --json`
- `opam exec -- dune runtest ocaml/`
- `python3 -m pytest tests/test_justfile.py tests/test_c2c_mcp_server_freshness.py tests/test_c2c_cli_dispatch.py -q`

Verification results:

- OCaml tests: `opam exec -- dune runtest ocaml/` passed.
- Targeted Python tests: 28 passed.
- OCaml CLI smoke test returned `{ "ok": true, ... }`.
- Built CLI version observed: `0.8.0 4684a99 2026-04-17T13:03:02Z`.

Size snapshot:

- OCaml production code sampled: `ocaml/c2c_mcp.ml` 2575 lines,
  `ocaml/cli/c2c.ml` 3877 lines, `ocaml/c2c_start.ml` 723 lines,
  `ocaml/relay.ml` 827 lines.
- OCaml tests sampled: `ocaml/test/test_c2c_mcp.ml` 4810 lines,
  `ocaml/test/test_relay.ml` 264 lines.
- Python still has 50+ top-level scripts, including active operational tools.
- Python tests still dominate breadth, with many integration and compatibility
  cases around wrappers, client setup, relay, wake daemons, and legacy managed
  harness behavior.

## What Is Now OCaml-Owned

The OCaml side owns the core product path:

- MCP stdio JSON-RPC server (`ocaml/c2c_mcp.ml`, `ocaml/server/`).
- File broker model under the git common dir, including registry, inboxes,
  locks, dead-letter queue, archive, rooms, and sweep behavior.
- Main CLI binary (`ocaml/cli/c2c.ml`) with broad subcommands:
  `send`, `list`, `whoami`, `poll-inbox`, `peek-inbox`, `send-all`, `sweep`,
  `sweep-dryrun`, `history`, `health`, `status`, `verify`, `register`,
  `refresh-peer`, `tail-log`, `my-rooms`, `dead-letter`, `prune-rooms`,
  `smoke-test`, `init`, `install`, `setup`, `serve`, `mcp`, `start`, `stop`,
  `restart`, `instances`, `rooms`, `room`, `relay`, `hook`, `inject`,
  and `screen`.
- Native `c2c setup` for Claude, Codex, Kimi, and OpenCode config generation.
- Native managed instance lifecycle entrypoints via `C2c_start`.
- Native memory-backed relay server path.
- Native install command for the `c2c` binary and optional MCP server copy.
- Development install path via `just install`, `just install-all`,
  `just install-rs`, `just bi`, and `just bii`.

This means the migration is no longer experimental at the core. The OCaml
binary is the default path for agents and humans who run `c2c`.

## What Still Depends On Python

Python remains live in these categories:

1. Relay support beyond the native memory server:
   - `c2c relay serve --storage sqlite` shells out to `c2c_relay_server.py`.
   - `relay connect`, `relay setup`, `relay status`, `relay list`,
     `relay rooms`, and `relay gc` shell out to Python scripts.

2. Delivery/wake daemons:
   - `C2c_start` still creates `python3` child processes for
     `c2c_deliver_inbox.py` and `c2c_poker.py`.
   - Kimi/OpenCode/Claude/Crush wake and bridge scripts are still Python.

3. Compatibility wrapper world:
   - `c2c_install.py` still installs many `c2c-*`, `run-*-inst*`, and
     restart wrappers.
   - `install-python-legacy` now makes this explicit, but the scripts still
     exist and are still tested.

4. Older Python CLI dispatcher:
   - `c2c_cli.py` imports and dispatches many subcommands that now overlap
     with native OCaml commands.
   - It remains useful as a compatibility map and test harness, but it is no
     longer the desired canonical entrypoint.

5. Client configure scripts:
   - Python configure scripts still exist for Claude, Codex, Kimi, Crush, and
     OpenCode, and tests still assert Python-based MCP wrapper config in places.
   - OCaml `c2c setup` has overlapping newer behavior.

6. Tests and fixtures:
   - Python tests are still the broadest coverage for legacy scripts,
     wrappers, relay, client setup, wake daemons, and compatibility behavior.
   - Removing Python without first porting this coverage would reduce
     confidence sharply.

## Documentation State

Documentation is inconsistent:

- `docs/architecture.md` correctly says the OCaml broker is the source of
  truth and documents the current file-backed broker.
- `README.md` is stale. It still frames the project as Claude-to-Claude PTY
  messaging experiments and lists Python wrapper commands as the main layout.
- `AGENTS.md` and `CLAUDE.md` say the OCaml side is source of truth but still
  include a long Python script inventory, including scripts that are now legacy
  or only compatibility paths.
- `docs/commands.md` includes OCaml `c2c mcp` entries, but command ownership is
  not consistently separated into native, compatibility, support daemon, and
  deprecated buckets.

This is causing real operational confusion: a user can read current architecture
docs and get one model, then read the README and infer the Python scripts are
still the canonical product.

## Risks

1. Dual-canonical paths

   There are now two overlapping command systems: native OCaml `c2c` and Python
   `c2c_cli.py` plus wrappers. Until documented and tested as compatibility
   only, agents may keep extending Python paths by habit.

2. Runtime Python hidden behind OCaml

   Users can run the OCaml binary and still end up depending on Python for
   relay subcommands and managed-session daemons. This is acceptable as a
   transition state, but it needs explicit command-level labeling.

3. Setup drift

   Python configure scripts and OCaml `c2c setup` may produce different MCP
   configs. This is especially risky because setup writes user-global config
   and stale MCP config has already caused startup failures.

4. Large OCaml files

   `ocaml/cli/c2c.ml` and `ocaml/c2c_mcp.ml` are both very large. Continuing
   to port features into these files without carving modules will make review
   and regression isolation harder.

5. Test ownership mismatch

   The OCaml product path depends on Python tests for broad behavioral
   confidence. That is fine temporarily, but the test suite should state which
   tests validate native behavior and which validate legacy behavior.

## Recommended Next Steps

### 1. Publish a migration map

Create a tracked document, probably `docs/ocaml-migration.md`, with one table:

- Native OCaml now
- Python compatibility path
- Python support daemon still required
- Deprecated / reference only
- Unknown / needs decision

This should become the authority for future agents before they touch a script.

### 2. Update the README immediately

Replace the old PTY-first README with a current quickstart:

- `just install`
- `c2c setup <client>`
- `c2c register`
- `c2c send`
- `c2c poll-inbox`
- `c2c rooms join swarm-lounge`
- short note that Python scripts are compatibility/support unless listed in the
  migration map.

This is low-risk and high-leverage because it changes agent behavior.

### 3. Split remaining Python into explicit buckets

Do not delete scripts in bulk. Add a manifest first:

- `python-runtime-required.txt` or a section in `docs/ocaml-migration.md`
- `python-legacy-wrappers`
- `python-test-fixtures`
- `python-deprecated-reference`

Then move only after tests and docs agree.

### 4. Port hidden runtime dependencies before deleting wrappers

Priority order:

1. Managed-session daemons used by `c2c start`:
   `c2c_deliver_inbox.py`, `c2c_poker.py`, Kimi/OpenCode/Claude wake paths.
2. Relay connector/status/config/gc and SQLite storage paths.
3. Client configure scripts still tested as Python MCP config writers.
4. Old one-command wrappers and legacy per-command Python dispatch.

The managed-session daemons should come before relay if local swarm reliability
is the main product goal.

### 5. Add command ownership tests

Add tests that assert:

- `just install` stays OCaml-only.
- `c2c --help` exposes native commands.
- Native commands do not shell out to Python except for an allowlisted set.
- Allowlisted Python shell-outs have a TODO/migration owner in the migration
  map.

This prevents Python from creeping back into the primary path.

### 6. Consolidate setup behavior

Pick `c2c setup` as canonical and make Python configure scripts either:

- wrappers around `c2c setup`, or
- explicitly legacy commands that print a deprecation warning.

Setup writes global client config, so divergence here is more dangerous than
divergence in read-only helper scripts.

### 7. Start modularizing OCaml before the next large port

Suggested first extractions:

- `Broker_cli` for broker-local CLI commands.
- `Setup` for per-client config generation.
- `Relay_cli` for relay command group and Python fallbacks.
- `Inject` or `Pty` for session/PTY/history injection.
- `Health` / `Status` for diagnostics rendering.

This can be gradual. The goal is to avoid turning `c2c.ml` into the new
monolith while retiring the old Python monolith.

## Suggested Near-Term Slice

Best next slice:

1. Add `docs/ocaml-migration.md` with the ownership table.
2. Update `README.md` to point to native `c2c` and the migration map.
3. Add a test that parses `ocaml/cli/c2c.ml` for `python3` shell-outs and
   compares them against an allowlist documented in `docs/ocaml-migration.md`.

Why this first: it prevents further confusion, gives future agents a routing
document, and creates a guardrail before more Python is removed.

Next implementation slice after that:

Port or replace the `c2c start` child daemons that are still launched through
Python. Those daemons sit on the local swarm critical path, which matters more
for the north-star goal than remote relay polish.

