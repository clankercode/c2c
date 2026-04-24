# OCaml Migration Status

This document tracks the migration of c2c functionality from Python/bash to OCaml.

## Overview

The OCaml implementation (`ocaml/`) is now the primary implementation. Python scripts
in the root directory are gradually being deprecated as their OCaml equivalents become
available and stable.

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully migrated to OCaml, Python is deprecated |
| 🔄 | Migrated but Python still used as fallback/reference |
| ⏳ | Not yet migrated, still needed |
| ❓ | Unknown / needs investigation |

## Core Broker Commands (`c2c` CLI)

| Command | OCaml Status | Python Script | Notes |
|---------|--------------|---------------|-------|
| `c2c send` | ✅ | `c2c_send.py` | Deprecated |
| `c2c send-all` | ✅ | `c2c_send_all.py` | Deprecated |
| `c2c list` | ✅ | `c2c_list.py` | Deprecated |
| `c2c whoami` | ✅ | `c2c_whoami.py` | Deprecated |
| `c2c poll-inbox` | ✅ | `c2c_poll_inbox.py` | Deprecated (hook binary now OCaml) |
| `c2c peek-inbox` | ✅ | - | Uses OCaml broker directly |
| `c2c history` | ✅ | `c2c_history.py` | Deprecated |
| `c2c health` | ✅ | `c2c_health.py` | Deprecated |
| `c2c register` | ✅ | `c2c_register.py` | Deprecated |
| `c2c sweep` | ✅ | `c2c_sweep_dryrun.py` | Dryrun in Python, sweep in OCaml |
| `c2c tail-log` | ✅ | - | OCaml only |
| `c2c my-rooms` | ✅ | - | OCaml only |
| `c2c dead-letter` | ✅ | `c2c_dead_letter.py` | Deprecated |
| `c2c prune-rooms` | ✅ | `c2c_prune.py` | Deprecated |
| `c2c smoke-test` | ✅ | `c2c_smoke_test.py` | Deprecated |
| `c2c install` | ✅ | `c2c_install.py` | OCaml is primary, Python still used for wrapper scripts |
| `c2c init` | ✅ | `c2c_init.py` | Deprecated |
| `c2c setup` | ✅ | `c2c_setup.py` | OCaml is primary |
| `c2c status` | ✅ | `c2c_status.py` | Deprecated |
| `c2c serve` / `c2c mcp` | ✅ | `c2c_mcp.py` | OCaml MCP is primary |
| `c2c start` | 🔄 | `c2c_start.py` | OCaml delegates to Python |
| `c2c stop` | ✅ | - | OCaml only |
| `c2c restart` | 🔄 | `c2c_start.py` | OCaml delegates to Python |
| `c2c instances` | ✅ | - | OCaml only |
| `c2c verify` | ✅ | `c2c_verify.py` | Deprecated |
| `c2c refresh-peer` | ✅ | `c2c_refresh_peer.py` | Deprecated |
| `c2c wake-peer` | ⏳ | `c2c_wake_peer.py` | Still Python (PTK injection) |
| `c2c watch` | ⏳ | `c2c_watch.py` | Still Python |

## Rooms Commands (`c2c rooms`)

| Command | OCaml Status | Notes |
|---------|--------------|-------|
| `c2c rooms list` | ✅ | OCaml only |
| `c2c rooms join` | ✅ | OCaml only |
| `c2c rooms leave` | ✅ | OCaml only |
| `c2c rooms send` | ✅ | OCaml only |
| `c2c rooms history` | ✅ | OCaml only |
| `c2c rooms invite` | ✅ | OCaml only |
| `c2c rooms members` | ✅ | OCaml only |
| `c2c rooms visibility` | ✅ | OCaml only |

## Relay Commands (`c2c relay`)

| Command | OCaml Status | Python Script | Notes |
|---------|--------------|---------------|-------|
| `c2c relay serve` | ✅ | `c2c_relay_server.py` | Deprecated |
| `c2c relay connect` | ⏳ | `c2c_relay_connector.py` | Still Python |
| `c2c relay setup` | ✅ | `c2c_relay_config.py` | Deprecated |
| `c2c relay status` | ✅ | `c2c_relay_status.py` | Deprecated |
| `c2c relay list` | ✅ | - | OCaml only |
| `c2c relay rooms` | ✅ | `c2c_relay_rooms.py` | Deprecated |
| `c2c relay gc` | ✅ | `c2c_relay_gc.py` | Deprecated |

## Client Configuration (`c2c configure-*`)

| Script | OCaml Status | Notes |
|--------|--------------|-------|
| `c2c_configure_claude_code.py` | ✅ | OCaml has `setup claude` |
| `c2c_configure_codex.py` | ✅ | OCaml has `setup codex` |
| `c2c_configure_kimi.py` | ✅ | OCaml has `setup kimi` |
| `c2c_configure_opencode.py` | ✅ | OCaml has `setup opencode` |
| `c2c_configure_crush.py` | ✅ | OCaml has `setup crush` |

## Wake Daemons (managed session auto-delivery)

| Script | OCaml Status | Notes |
|--------|--------------|-------|
| `c2c_claude_wake_daemon.py` | ⏳ | Still Python (PTY injection) |
| `c2c_kimi_wake_daemon.py` | ⏳ | Still Python (PTY injection) |
| `c2c_kimi_wire_bridge.py` | ⏳ | Still Python (Wire protocol) |
| `c2c_opencode_wake_daemon.py` | ⏳ | Still Python (PTY injection) |
| `c2c_crush_wake_daemon.py` | ⏳ | Still Python (PTY injection) |
| `c2c_deliver_inbox.py` | ⏳ | Still Python (inotify-based delivery) |

## Low-Level / Infrastructure

| Script | OCaml Status | Notes |
|--------|--------------|-------|
| `c2c_registry.py` | 🔄 | Python lib, OCaml has own implementation |
| `c2c_broker_gc.py` | ⏳ | Python (standalone GC) |
| `c2c_poker.py` | ⏳ | Still Python (PTY poker) |
| `c2c_poker_sweep.py` | ⏳ | Still Python |
| `c2c_pts_inject.py` | ⏳ | Still Python (legacy PTY injection) |
| `c2c_inject.py` | ⏳ | Still Python |
| `c2c_kimi_prefill.py` | ⏳ | Still Python |
| `c2c_relay_contract.py` | ⏳ | Still Python |
| `c2c_relay_sqlite.py` | ⏳ | Still Python |

## Scripts Recommended for Deprecation/Archival

These scripts have OCaml equivalents and can be moved to `deprecated/`:

```
deprecated/
├── c2c_send.py           # → c2c send
├── c2c_send_all.py       # → c2c send-all
├── c2c_list.py           # → c2c list
├── c2c_whoami.py         # → c2c whoami
├── c2c_poll_inbox.py     # → c2c poll-inbox (hook is now OCaml)
├── c2c_history.py        # → c2c history
├── c2c_health.py         # → c2c health
├── c2c_register.py       # → c2c register
├── c2c_dead_letter.py    # → c2c dead-letter
├── c2c_prune.py          # → c2c prune-rooms
├── c2c_smoke_test.py     # → c2c smoke-test
├── c2c_init.py           # → c2c init
├── c2c_status.py         # → c2c status
├── c2c_verify.py         # → c2c verify
├── c2c_refresh_peer.py   # → c2c refresh-peer
├── c2c_setup.py          # → c2c install <client> (OCaml primary)
├── c2c_relay_config.py   # → c2c relay setup
├── c2c_relay_status.py   # → c2c relay status
├── c2c_relay_rooms.py    # → c2c relay rooms
├── c2c_relay_gc.py       # → c2c relay gc
└── c2c_watch.py          # → needs OCaml implementation
```

## Still Needed (No OCaml Equivalent)

These scripts are in `deprecated/` — some are still imported by `c2c_cli.py` (Python CLI shim),
some have OCaml equivalents, and some are retained as experimental fallback paths.

| Script | Location | Status |
|--------|----------|--------|
| `c2c_start.py` | root | 🔄 OCaml `c2c start` is primary; Python still used for some launch paths |
| `c2c_install.py` | root | 🔄 OCaml `just install-all` is primary; Python for wrapper scripts |
| `c2c_cli.py` | root | 🔄 Python CLI shim; OCaml `c2c` is primary binary |
| `c2c_mcp.py` | root | 🔄 Python MCP server; OCaml `c2c serve` is primary |
| `c2c_registry.py` | root | 🔄 Python registry lib; OCaml has own implementation |
| `c2c_deliver_inbox.py` | root | 🔄 inotify-based delivery daemon; OCaml `c2c-deliver-inbox` is primary |
| `c2c_claude_wake_daemon.py` | deprecated/ | 🔄 PTY-based; retained for experimental use |
| `c2c_kimi_wake_daemon.py` | deprecated/ | 🔄 PTY-based; retained for experimental use |
| `c2c_kimi_wire_bridge.py` | deprecated/ | 🔄 Wire protocol bridge; OCaml `c2c wire-daemon` is primary |
| `c2c_opencode_wake_daemon.py` | deprecated/ | 🔄 PTY-based; retained for experimental use |
| `c2c_crush_wake_daemon.py` | deprecated/ | 🔄 PTY-based; Crush not first-class peer |
| `c2c_pts_inject.py` | root | 🔄 PTY injection utility; deprecated path |
| `c2c_inject.py` | deprecated/ | 🔄 Injection utility; root shim routes to deprecated/ |
| `c2c_poker.py` | root | 🔄 PTY poker; OCaml `c2c poker` is primary |
| `c2c_poker_sweep.py` | root | 🔄 Poker sweep |
| `c2c_broker_gc.py` | root | 🔄 Standalone broker GC |
| `c2c_sweep_dryrun.py` | root | 🔄 Sweep dryrun |
| `c2c_kimi_prefill.py` | root | 🔄 Kimi prefill |
| `c2c_relay_connector.py` | root | 🔄 Relay connector |
| `c2c_relay_server.py` | deprecated/ | 🔄 Relay server; OCaml relay is primary |
| `c2c_relay_contract.py` | deprecated/ | 🔄 Relay contract |
| `c2c_relay_sqlite.py` | deprecated/ | 🔄 Root shim routes to deprecated/; OCaml relay uses SQLite directly |
| `c2c_relay_gc.py` | deprecated/ | 🔄 Root shim routes to deprecated/; OCaml `c2c relay gc` is primary |
| `c2c_room.py` | root | 🔄 Room utilities |
| `c2c_wake_peer.py` | root | 🔄 Wake peer utility |
| `relay.py`, `c2c_relay.py`, `c2c_auto_relay.py` | deprecated/ | 🔄 Legacy relay scripts |

Key: 🔄 = deprecated/root but still imported or used as fallback; ✅ = fully deprecated with OCaml replacement

## Migration Checklist

### Phase 1: Core Broker (DONE)
- [x] send/send-all
- [x] list/whoami
- [x] poll-inbox/peek-inbox
- [x] history
- [x] health
- [x] register
- [x] dead-letter
- [x] prune-rooms
- [x] smoke-test
- [x] init
- [x] status
- [x] verify
- [x] refresh-peer
- [x] rooms (all subcommands)
- [x] relay (most subcommands)
- [x] instances
- [x] stop
- [x] configure-* scripts

### Phase 2: Managed Instances
- [ ] `c2c start` - OCaml delegates to Python, could be native
- [ ] `c2c restart` - OCaml delegates to Python, could be native

### Phase 3: Wake Daemons
- [ ] c2c_claude_wake_daemon.py → OCaml?
- [ ] c2c_kimi_wake_daemon.py → OCaml?
- [ ] c2c_kimi_wire_bridge.py → OCaml?
- [ ] c2c_opencode_wake_daemon.py → OCaml?
- [ ] c2c_crush_wake_daemon.py → OCaml?
- [ ] c2c_deliver_inbox.py → OCaml?

### Phase 4: Low-Level Utilities
- [ ] c2c_poker.py
- [ ] c2c_pts_inject.py
- [ ] c2c_inject.py
- [ ] c2c_broker_gc.py
- [ ] c2c_sweep_dryrun.py
- [ ] c2c_kimi_prefill.py
- [ ] c2c_watch.py

### Phase 5: Relay
- [ ] c2c_relay_connector.py
- [ ] c2c_relay_server.py
- [ ] c2c_relay_contract.py
- [ ] c2c_relay_sqlite.py

### Phase 6: Legacy Cleanup
- [ ] c2c_cli.py (Python CLI entry point)
- [ ] c2c_mcp.py (Python MCP server)
- [ ] c2c_registry.py (Python registry lib)
- [ ] c2c_start.py (once Phase 2 complete)
- [ ] relay.py, c2c_relay.py, c2c_auto_relay.py

## Safe Script Deprecation Rules

A Python script can ONLY be moved to `deprecated/` when ALL of these conditions are met:

1. **No `c2c_cli.py` import** - `c2c_cli.py` must not import it directly
2. **No OCaml delegation** - OCaml code must not use `find_python_script` to call it
3. **No transitive imports** - No other Python script that IS still needed should import it
4. **Tests pass** - All tests that reference the script must be updated first

### Scripts Currently Safe to Deprecate

These scripts meet all criteria above (no imports, no delegation):

```
deprecated/
└── c2c_auto_relay.py  ✅ Moved
```

### Scripts NOT Yet Safe to Deprecate

Most scripts are NOT safe because `c2c_cli.py` imports them:

| Script | Reason |
|--------|--------|
| `c2c_send.py` | Imported by `c2c_cli.py` |
| `c2c_list.py` | Imported by `c2c_cli.py` |
| `c2c_whoami.py` | Imported by `c2c_cli.py` |
| `c2c_health.py` | Imported by `c2c_cli.py` |
| `c2c_init.py` | Imported by `c2c_cli.py` |
| `c2c_setup.py` | Imported by `c2c_cli.py` |
| (most others) | Similar pattern |

### How to Safely Deprecate a Script

1. **Verify no dependencies** - Check `grep "^import script_name" c2c_*.py`
2. **Update OCaml if needed** - Remove any `find_python_script` calls in `ocaml/cli/c2c.ml`
3. **Update tests** - Ensure tests don't reference the Python script
4. **Move to deprecated/** - `git mv script.py deprecated/`
5. **Commit** - Document why it's deprecated
6. **Verify build** - `just build-cli && just test`

### Relay Note

OCaml relay implementations exist as untracked WIP:
- `ocaml/relay.ml` (in-memory relay backend)
- `ocaml/relay_server.ml` (HTTP server with Cohttp)

These need dune files updated and OCaml CLI integration before the Python relay scripts can be deprecated.
