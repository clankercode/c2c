# Root Python file usage audit

Repo root: `/home/xertrov/src/c2c`
Scope: `*.py` files directly in the repo root (not in `ocaml/`, `tests/`, `scripts/`, `docs/`, `gui/`, `docker-tests/`, `deprecated/`, `__pycache__/`, etc.)

## Methodology

For each root `*.py` file I searched for:

- Imports/references in Python source under `ocaml/`, `tests/`, `scripts/`, `docker-tests/`
- Root executable wrapper scripts (files without `.py` that `exec python3 <file>`)
- `justfile`, shell scripts, Dockerfiles, `docker-compose*.yml`
- `docs/`, `README.md`, and other markdown references
- Deprecated markers in docstrings/headers or README tables

Files that are imported, executed by a wrapper, referenced by build/deploy configuration, or documented as actively-used operational helpers are marked **used**. Files with no in-repo functional references are marked **unused**. I was conservative: anything referenced only dynamically or only in docs is noted.

## Summary

- Total root `*.py` files: **61**
- Used: **55**
- Unused: **6** — `claude_read_history.py`, `connect_abstract.py`, `connect_ipc.py`, `investigate_socket.py`, `relay.py`, `send_to_session.py`

## Detailed findings

| File | Used | Evidence | Recommendation |
|------|------|----------|----------------|
| `c2c_broker_gc.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-broker-gc`; imported by `/home/xertrov/src/c2c/c2c_cli.py`, `/home/xertrov/src/c2c/c2c_mcp.py`, `/home/xertrov/src/c2c/c2c_refresh_peer.py`, `/home/xertrov/src/c2c/c2c_dead_letter.py`; tested in `tests/test_c2c_maintenance.py` | keep |
| `c2c_cli.py` | yes | Root shim `/home/xertrov/src/c2c/c2c` delegates to it; wrappers `c2c-start`, `c2c-stop`, `c2c-send`, `c2c-list`, `c2c-instances`, `c2c-verify`, `c2c-whoami`, `c2c-register`, `c2c-restart`, `c2c-restart-me`, `c2c-wake-peer` call it; tested in `tests/test_c2c_cli*.py` | keep |
| `c2c_configure_claude_code.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; referenced by `/home/xertrov/src/c2c/c2c_setup.py` | keep |
| `c2c_configure_codex.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_configure_codex.py` | keep |
| `c2c_configure_crush.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; references `c2c_mcp.py` | keep |
| `c2c_configure_kimi.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; references `c2c_mcp.py` | keep |
| `c2c_configure_opencode.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_configure_opencode.py` | keep |
| `c2c_coord_cherry_pick.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-coord-cherry-pick` calls it; imported by `/home/xertrov/src/c2c/c2c_cli.py` | keep |
| `c2c_dead_letter.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_dead_letter.py` | keep |
| `c2c_deliver_inbox.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-deliver-inbox`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; copied in `Dockerfile.agent`; referenced by `ocaml/c2c_start.mli`; tested in `tests/test_c2c_deliver_inbox*.py` | keep |
| `c2c_health.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-health`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_health.py` | keep |
| `c2c_history.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_history.py`; deprecated in runbooks but still backs `c2c history` | keep |
| `c2c_init.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-init`; imported by `/home/xertrov/src/c2c/c2c_cli.py` | keep |
| `c2c_inject.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-inject`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_messaging.py`; README marks deprecated but still active | keep |
| `c2c_install.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-install` calls `c2c_cli.py install`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; `justfile` recipe `install-python-legacy` calls it; tested in `tests/test_c2c_install*.py` | keep |
| `c2c_kimi_prefill.py` | yes | Referenced by `/home/xertrov/src/c2c/run-kimi-inst` (`PREFILL_SHIM`); tested in `tests/test_c2c_kimi_crush.py`; listed in test fixtures | keep |
| `c2c_kimi_wake_daemon.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-kimi-wake`; tested in `tests/test_c2c_kimi_wake_daemon.py`; referenced by `ocaml/cli/c2c.ml` | keep |
| `c2c_list.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-list` calls `c2c_cli.py list`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_registry_list.py` | keep |
| `c2c_mcp.py` | yes | Imported by `c2c_cli.py`, `c2c_poll_inbox.py`, `c2c_init.py`, `c2c_history.py`, all `c2c_configure_*.py`, `c2c_list.py`, `c2c_send.py`, `c2c_whoami.py`, `c2c_room.py`, `c2c_send_all.py`, `c2c_broker_gc.py`, `c2c_status.py`, `c2c_health.py`, `c2c_wake_peer.py`, `c2c_relay_rooms.py`; copied in `Dockerfile.agent`; configure scripts reference it as `C2C_MCP_PATH`; tested extensively | keep |
| `c2c_opencode_wake_daemon.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-opencode-wake`; tested in `tests/test_c2c_opencode_wake_daemon.py`; referenced by `ocaml/cli/c2c.ml` | keep |
| `c2c_poker.py` | yes | Imported by `c2c_deliver_inbox.py`, `c2c_poker_sweep.py`; spawned by OCaml `c2c_poker.ml`/`c2c_start.ml`; copied in `Dockerfile.agent`; tested in `tests/test_c2c_poker.py` | keep |
| `c2c_poker_sweep.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-poker-sweep`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_poker_sweep.py` | keep |
| `c2c_poll_inbox.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-poll-inbox`; imported by `c2c_cli.py`, `c2c_deliver_inbox.py`, `c2c_wire_daemon.py`; copied in `Dockerfile.agent`; tested in `tests/test_c2c_poll_inbox.py` | keep |
| `c2c_prune.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-prune`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_verify_whoami.py` | keep |
| `c2c_pts_inject.py` | yes | Imported by `deprecated/c2c_kimi_wake_daemon.py`; tested in `tests/test_c2c_pts_inject.py`; whitelisted in `scripts/c2c-dup-scanner.py`; header says DEPRECATED | keep (legacy dependency) |
| `c2c_pty_inject.py` | yes | Imported by `claude_send_msg.py`, `c2c_poker.py`, `c2c_restart_me.py`; tested in `tests/test_c2c_pty_inject.py` | keep |
| `c2c_refresh_peer.py` | yes | Lazy-imported by `c2c_cli.py`; used by `c2c_wire_daemon.py`; referenced by `run-claude-inst-outer`, `run-opencode-inst-outer`, `run-crush-inst-outer`; tested in `tests/test_c2c_maintenance.py` | keep |
| `c2c_register.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-register` calls `c2c_cli.py register`; imported by `c2c_cli.py`; tested in `tests/test_c2c_registry_list.py` | keep |
| `c2c_registry.py` | yes | Imported by `c2c_mcp.py`, `c2c_whoami.py`, `c2c_list.py`, `c2c_register.py`, `c2c_prune.py`, `c2c_verify.py`, `c2c_send.py`; copied in `Dockerfile.agent`; tested extensively | keep |
| `c2c_relay_config.py` | yes | Imported by `c2c_relay_rooms.py`, `c2c_relay_status.py`, `c2c_health.py`, `c2c_cli.py`; tested in `tests/test_relay_config_status.py` | keep |
| `c2c_relay_connector.py` | yes | Imported by `c2c_relay_rooms.py`, `c2c_relay_status.py`, `c2c_health.py`, `c2c_cli.py`; used as fallback by `ocaml/cli/c2c.ml`; tested in `tests/test_relay_connector.py`, `tests/test_c2c_relay_connector.py` | keep |
| `c2c_relay_contract.py` | yes | Imported by `c2c_relay_server.py`, `c2c_relay_connector.py`, `c2c_relay_rooms.py`, `c2c_relay_config.py`; many tests import it | keep |
| `c2c_relay_gc.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_relay_gc.py` | keep |
| `c2c_relay_rooms.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_relay_rooms.py`, `tests/test_relay_rooms_cli.py` | keep |
| `c2c_relay_server.py` | yes | Imported by `c2c_relay_rooms.py`, `c2c_cli.py`; tested in `tests/test_relay_server.py`, `tests/test_c2c_relay_server.py`, `tests/test_relay_sqlite.py`, etc. | keep |
| `c2c_relay_sqlite.py` | yes | Imported by `c2c_relay_server.py`; tested in `tests/test_relay_sqlite.py` | keep |
| `c2c_relay_status.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_relay_config_status.py` | keep |
| `c2c_restart_me.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_cli_support.py` | keep |
| `c2c_room.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-room`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_room.py` | keep |
| `c2c_send.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-send` calls `c2c_cli.py send`; imported by `c2c_cli.py`, `c2c_watch.py`, `c2c_dead_letter.py`; tested in `tests/test_c2c_messaging.py`, `tests/test_c2c_registry_list.py` | keep |
| `c2c_send_all.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-send-all`; imported by `/home/xertrov/src/c2c/c2c_cli.py` | keep |
| `c2c_setcap.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; called by `ocaml/cli/c2c.ml` | keep |
| `c2c_setup.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-setup`; imported by `/home/xertrov/src/c2c/c2c_cli.py` | keep |
| `c2c_sitrep.py` | yes | Referenced as the operational sitrep helper in `.sitreps/PROTOCOL.md`, `.c2c/roles/builtins/Cairn-Vigil.md`, `ocaml/cli/role_templates.ml` | keep |
| `c2c_smoke_test.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_smoke_test.py` | keep |
| `c2c_start.py` | yes | Imported by `tests/test_c2c_start.py`; `MIGRATION_STATUS.md` notes Python still used for some launch paths | keep |
| `c2c_status.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_status.py` | keep |
| `c2c_sweep_dryrun.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_sweep_dryrun.py`, `tests/test_c2c_cli_dispatch.py`, `tests/test_c2c_maintenance.py` | keep |
| `c2c_verify.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-verify` calls `c2c_cli.py verify`; imported by `c2c_cli.py`, `c2c_status.py`; tested in `tests/test_c2c_verify_whoami.py` | keep |
| `c2c_wake_peer.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_maintenance.py` | keep |
| `c2c_watch.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-watch`; imported by `/home/xertrov/src/c2c/c2c_cli.py`; tested in `tests/test_c2c_watch.py` | keep |
| `c2c_whoami.py` | yes | Wrapper `/home/xertrov/src/c2c/c2c-whoami` calls `c2c_cli.py whoami`; imported by `c2c_cli.py`, `c2c_mcp.py`, `c2c_health.py`, `c2c_room.py`, `c2c_relay_rooms.py`; tested in `tests/test_c2c_cli_identity.py` | keep |
| `c2c_wire_daemon.py` | yes | Imported by `/home/xertrov/src/c2c/c2c_cli.py`, `/home/xertrov/src/c2c/c2c_health.py`; tested in `tests/test_c2c_wire_daemon.py`, `tests/test_c2c_health.py` | keep |
| `claude_list_sessions.py` | yes | Imported by `c2c_whoami.py`, `c2c_list.py`, `c2c_register.py`, `c2c_prune.py`, `c2c_send.py`, `c2c_mcp.py`, `c2c_poker.py`, `claude_send_msg.py`; tested in `tests/test_c2c_messaging.py`; referenced by `ocaml/cli/c2c.ml`; README marks deprecated but heavily used | keep |
| `claude_send_msg.py` | yes | Imported by `c2c_send.py`, `c2c_register.py`; tested in `tests/test_c2c_messaging.py`, `tests/test_c2c_registry_list.py`; README marks deprecated but still used | keep |
| `claude_read_history.py` | no | No imports or in-repo execution references; README marks it "Deprecated (Tier 4 / legacy)"; the root wrapper `claude-read-history` points to `/home/xertrov/src/c2c-msg/claude_read_history.py` (different repo) | move to `deprecated-python/` |
| `connect_abstract.py` | no | No imports or execution references; listed as experimental/pre-broker artifact in `docs/architecture.md` and `.collab/runbooks/python-scripts-deprecated.md` | move to `deprecated-python/` |
| `connect_ipc.py` | no | No imports or execution references; listed as experimental/pre-broker artifact in `docs/architecture.md` and `.collab/runbooks/python-scripts-deprecated.md` | move to `deprecated-python/` |
| `investigate_socket.py` | no | No imports or execution references; listed as experimental/pre-broker artifact in `docs/architecture.md` and `.collab/runbooks/python-scripts-deprecated.md` | move to `deprecated-python/` |
| `relay.py` | no | No imports or execution references; `docs/architecture.md`, `.collab/runbooks/python-scripts-deprecated.md`, `survival-guide/our-journey.md` describe it as deprecated legacy PTY-based relay | move to `deprecated-python/` |
| `send_to_session.py` | no | No imports or execution references; `docs/communication-tiers.md`, `docs/MSG_IO_METHODS.md`, `.collab/runbooks/python-scripts-deprecated.md` describe it as experimental | move to `deprecated-python/` |

## Notes

- Several files are explicitly marked deprecated in `README.md` or runbooks (e.g. `c2c_inject.py`, `c2c_history.py`, `claude_send_msg.py`, `claude_list_sessions.py`, `c2c_pts_inject.py`) but are still imported or executed by active code/tests, so they cannot be moved without updating their callers.
- The root wrappers `c2c-claude-wake`, `c2c-crush-wake`, and `c2c-kimi-wire-bridge` reference Python files that live under `deprecated/` (`c2c_claude_wake_daemon.py`, `c2c_crush_wake_daemon.py`, `c2c_kimi_wire_bridge.py`), not in the repo root. Those files were outside the scope of this audit.
- No files were moved; this is an audit-only report awaiting review.
