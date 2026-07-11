# B123 — Deprecated Python still user-facing (fresh audit)

**Date:** 2026-07-11  
**Worktree:** `.worktrees/bl-b123` / branch `slice/b123`  
**North star:** OCaml `c2c` binary is canonical. Python is OK in tests/codegen; **not** as a product path.

## Supersedes

`deprecated-python/audit-report.md` (undated prior audit) classified almost everything as **keep** based on "is imported / has a wrapper / has a test". That is the wrong axis for B123. This audit re-classifies by **user-facing product surface** vs test/tooling.

## Methodology

1. Inventory root `c2c_*.py` / `claude_*.py`, root shell wrappers `c2c-*`, `just install-python-legacy`, `Dockerfile.agent`, survival-guide recipes, docs that tell operators to run Python.
2. Map each surface to OCaml (`c2c <subcommand>`, `c2c-mcp-server`, `c2c-deliver-inbox` from `just install-all`).
3. Classify:
   - `user-facing-active` — product path still runnable without escape hatch (**bad**)
   - `user-facing-deprecated-but-reachable` — still installable/runnable but refuses or is documented retired
   - `test-only` — OK
   - `codegen/tooling` — OK if not product path
   - `dead/unused` — candidate quarantine/delete
4. Remediate wrappers / install / Docker / survival-guide in this slice (prefer refuse over mass delete of test-backed Python).

## Summary counts (post-remediation)

| Category | Count (approx) | Notes |
|----------|----------------|-------|
| Root `*.py` product-adjacent (still on disk) | ~54 | Kept for tests; not product PATH |
| Root wrappers `c2c-*` retired (refuse) | 35 | Exit 2 unless `C2C_ALLOW_PYTHON_LEGACY=1` or pytest |
| `user-facing-active` (residual after slice) | few | see Residual |
| `user-facing-deprecated-but-reachable` | wrappers + `c2c_install.py` + `just install-python-legacy` | refuse by default |
| `test-only` | `tests/**`, `docker-tests/**` | OK |
| `codegen/tooling` | `tools/ci/*.py`, some `scripts/*.py` | OK |
| `dead/unused` | `deprecated-python/*`, some `deprecated/*` | already quarantined |

### Counts by classification (root Python modules)

| Class | N | Examples |
|-------|---|----------|
| user-facing-deprecated-but-reachable (module still importable; wrappers refuse) | ~40 | `c2c_send.py`, `c2c_mcp.py`, `c2c_cli.py`, … |
| test-library residual (imported by product-adjacent Python + tests) | ~10 | `c2c_registry.py`, `c2c_relay_contract.py`, … |
| dead/stub re-exports | ~5 | `c2c_inject.py` → `deprecated.*`, wake daemon stubs |
| operational agent helper (not install product, still scripts) | ~3 | `c2c_sitrep.py`, `c2c_kimi_prefill.py`, `scripts/c2c_tmux.py` |

## Table — root wrappers

| Wrapper | Pre-B123 | OCaml replacement | Post-B123 class |
|---------|----------|-------------------|-----------------|
| `c2c-send` | `python3 c2c_cli.py send` | `c2c send` | user-facing-deprecated-but-reachable (refuse) |
| `c2c-send-all` | python | `c2c send-all` | refuse |
| `c2c-list` | python | `c2c list` | refuse |
| `c2c-register` | python | `c2c register` | refuse |
| `c2c-whoami` | python | `c2c whoami` | refuse |
| `c2c-poll-inbox` | python | `c2c poll-inbox` | refuse |
| `c2c-health` | python | `c2c health` | refuse |
| `c2c-room` | python | `c2c rooms` / `c2c room` | refuse |
| `c2c-init` | python | `c2c init` | refuse |
| `c2c-install` | python install wrappers | `c2c install` / `just install-all` | refuse |
| `c2c-start` / `stop` / `restart` / `instances` | python | `c2c start|stop|restart|instances` | refuse |
| `c2c-setup` | python configure | `c2c install <client>` | refuse |
| `c2c-verify` | python | `c2c verify` | refuse |
| `c2c-watch` | python | `c2c watch` | refuse |
| `c2c-inject` | python | `c2c inject` / `c2c dev inject` | refuse |
| `c2c-restart-me` | python | `c2c restart-self` | refuse |
| `c2c-wake-peer` | python PTY nudge | `c2c deliver wake-watch` (partial) | refuse |
| `c2c-poker-sweep` | python | none (legacy poker hygiene) | refuse |
| `c2c-broker-gc` | python | `c2c sweep` / `c2c sweep-dryrun` | refuse |
| `c2c-prune` | python YAML prune | `c2c registry-prune` / `c2c sweep` | refuse |
| `c2c-deliver-inbox` | python | OCaml `~/.local/bin/c2c-deliver-inbox` | refuse (repo wrapper) |
| `c2c-configure-*` | python | `c2c install <client>` | refuse |
| `c2c-coord-cherry-pick` | broken path to `.py` | `c2c coord-cherry-pick` | refuse |
| `c2c-*-wake`, `c2c-kimi-wire-bridge` | python / missing | schedules / hooks / notifier | refuse (no legacy) |
| `c2c-inbox-hook`, `c2c-cold-boot-hook` | OCaml `_build` | already OCaml | OK (not Python) |

## Table — root `*.py` (selected)

| File | Class | OCaml / notes |
|------|-------|---------------|
| `c2c_cli.py` | user-facing-deprecated-but-reachable | Dispatcher; escape hatch only |
| `c2c` (repo shim) | prefers OCaml | Native-first; no silent Python install path |
| `c2c_install.py` | refuse by default | `just install-all` / `c2c install` |
| `c2c_mcp.py` | deprecated module | `c2c mcp` / `c2c-mcp-server` |
| `c2c_send.py` / `list` / `whoami` / … | test-backed | wrappers refuse |
| `c2c_deliver_inbox.py` | test-backed | OCaml deliver binary primary |
| `c2c_poker.py` | residual library | managed wake preferred |
| `c2c_wake_peer.py` | residual | no full OCaml twin |
| `c2c_start.py` | residual / partial | OCaml `c2c start` primary |
| `c2c_registry.py` | library | still imported by Python tests |
| `c2c_relay_*.py` | test + some residual | OCaml relay primary |
| `c2c_sitrep.py` | agent helper | role templates may reference |
| `c2c_kimi_prefill.py` | launch helper | `run-kimi-inst` |
| stubs (`c2c_inject.py`, wake daemons) | dead re-export | `deprecated/` |
| `claude_list_sessions.py` / `claude_send_msg.py` | legacy PTY helpers | tests still import |
| `deprecated-python/*` | dead/unused | already moved |

## Install / Docker / docs

| Surface | Pre-B123 | Post-B123 |
|---------|----------|-----------|
| `just install` / `install-all` | OCaml only | unchanged (good) |
| `just install-python-legacy` | silently ran `python3 c2c_install.py` | **refuses** unless `C2C_ALLOW_PYTHON_LEGACY=1` |
| `c2c_install.py` | installed 40+ Python wrappers to `~/.local/bin` | **refuses** unless escape hatch |
| `Dockerfile.agent` | COPYed `c2c_deliver_inbox.py` + deps + Python shim | OCaml `c2c` + `c2c-deliver-inbox` only |
| survival-guide recipes | `python3 c2c_send.py`, `c2c-poll-inbox`, poker | OCaml `c2c …` |
| Docs `get-started.md` | already OCaml-forward | no change required this slice |
| Historical `docs/superpowers/**` | many Python recipes | left as historical plans (not product front door) |

## Remediation applied in this slice

1. All product `c2c-*` Python wrappers **refuse** (exit 2) with pointer to OCaml; escape hatch `C2C_ALLOW_PYTHON_LEGACY=1` (and auto-allow under `PYTEST_CURRENT_TEST` so the Python test suite still exercises modules).
2. `c2c_install.py` + `just install-python-legacy` **refuse** by default.
3. Repo-root `./c2c` shim is **native-first**; lifecycle commands fail closed without native; no force-Python except escape hatch.
4. `Dockerfile.agent` ships OCaml deliver binary, not Python MCP/deliver.
5. Survival-guide operator recipes updated off Python paths.
6. Tests updated for refuse semantics (`test_justfile`, `test_c2c_install`).

## Residual user-facing / operator-adjacent Python (honest)

After this slice, the following can still be reached without the escape hatch if someone runs modules **directly** (`python3 c2c_*.py`):

1. **Direct module exec** — `python3 c2c_send.py` etc. still run (shebang scripts). Wrappers and install path refuse; modules kept for tests. Follow-up: add deprecation banner / SystemExit in `main()` for each, or move under `deprecated/` once tests import from a package path.
2. **`c2c_kimi_prefill.py`** via `run-kimi-inst` launch scripts — managed path residual.
3. **`c2c_sitrep.py`** referenced by role/protocol docs as a helper script.
4. **`scripts/c2c_tmux.py`** — **intentional** live-peer testing tool (CLAUDE.md); not product messaging path.
5. **`run-*-inst*`** outer scripts — legacy launchers; product path is `c2c start`.
6. **Historical docs** under `docs/superpowers/**` still mention Python (not front-door get-started).
7. **Relay Python modules** still importable; production relay is OCaml Docker/Railway path.
8. **`claude_list_sessions.py` / `claude_send_msg.py` / `c2c_pty_inject.py`** — still importable for PTY experiments; not installed by `just install-all`.

No `~/.local/bin` Python wrappers are installed by the canonical install path (`just install-all` only copies OCaml binaries + `cc-quota`).

## Escape hatch (tests / emergency)

```bash
C2C_ALLOW_PYTHON_LEGACY=1 ./c2c-send …
C2C_ALLOW_PYTHON_LEGACY=1 python3 c2c_install.py
C2C_ALLOW_PYTHON_LEGACY=1 just install-python-legacy
```

Pytest sets `PYTEST_CURRENT_TEST`, which root wrappers treat as allow so existing Python unit tests keep working without rewriting every `run_cli("c2c-send", …)` helper.

## Recommended follow-ups (out of scope / next slices)

- Banner or refuse inside each `c2c_*.py` `main()` when not under tests.
- Move retired modules under `deprecated-python/` once import paths in tests are updated.
- Delete or archive `run-*-inst*` once fully unused.
- Doc hygiene pass on `docs/superpowers/**` historical plans (or mark archival).
- Coordinate with B122 (MCP install opt-in) — do not reintroduce Python MCP install routes.
