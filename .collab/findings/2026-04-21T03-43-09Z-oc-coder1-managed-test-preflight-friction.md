## Symptom

Running focused `c2c start` regressions via `just test-one -k ...` failed before test execution because the shared dev machine had multiple live swarm processes:

- `c2c-mcp-server: 2 running (limit 1)`
- `c2c-start: 10 running (limit 2)`

Pytest suggested killing them or bypassing with `--force-test-env`.

## How I discovered it

I tried to verify an OCaml `c2c_start` registry-cleanup fix with:

```bash
just test-one -k "clean_exit_strips_only_managed_pid_fields_and_preserves_mode or exit109"
```

The suite aborted in conftest preflight before running the targeted tests.

## Root cause

The global pytest preflight is tuned for a mostly-isolated developer machine, but active swarm work routinely keeps many managed `c2c start` instances alive. That makes narrow regression runs fail for environmental reasons unrelated to the code under test.

The reported `c2c-mcp-server: 2 running` count was a false positive in the leak matcher, not a real managed-session broker leak. `tests/conftest.py` used `pgrep -f 'c2c_mcp_server\.exe'`, which also matched `dune build ... ./ocaml/server/c2c_mcp_server.exe ...` compile jobs. A direct repro with `~/.local/bin/c2c start opencode -n repro-clean-exit --bin /bin/true` confirmed that clean `c2c start` exit does not grow the live broker PID set.

## Fix status

Partially fixed in this slice.

- Tightened `tests/conftest.py` so `c2c-mcp-server` leak detection only counts real `c2c_mcp_server.exe` processes, excluding `dune`/`opam`/shell wrapper build jobs that merely mention the path.
- Confirmed the focused `c2c start` regression no longer emits the spurious broker-leak warning.

Remaining workaround for swarm mode:

```bash
python3 -m pytest tests/test_c2c_start.py -k 'clean_exit_strips_only_managed_pid_fields_and_preserves_mode or exit109' -v --tb=short --force-test-env
```

This is still needed on a busy shared machine because the `c2c-start` preflight count is a real ambient condition, not a false positive.

## Severity

Medium. It does not break production behavior, but the false broker-leak signal wasted debugging time and can encourage unsafe cleanup habits (`pkill`, sweeping, etc.) during test verification.
