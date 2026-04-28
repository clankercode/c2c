# documented c2c sweep-dryrun subcommand was not wired

## Symptom

`./c2c sweep-dryrun --json` returned `unknown c2c subcommand: sweep-dryrun`
even though `c2c_sweep_dryrun.py` exists and AGENTS.md documents it as a safe
alternative to live sweep during active swarm operation.

## Discovery

After health identified inactive inbox artifacts and duplicate PID ghosts, codex
tried to run the documented safe cleanup preview. The top-level dispatcher
failed before reaching the dry-run script.

## Root Cause

`c2c_cli.py` did not import or dispatch `c2c_sweep_dryrun`. After adding that
dispatch, the live path exposed a second mismatch: `c2c_sweep_dryrun.main()`
parsed `sys.argv` directly and did not accept an argv list like the rest of the
top-level subcommand modules.

## Fix Status

Fixed by wiring `sweep-dryrun` into the top-level `c2c` dispatcher and updating
`c2c_sweep_dryrun.main(argv=None)` to accept forwarded arguments. Live
`./c2c sweep-dryrun --json` now returns a read-only preview.

## Severity

Medium. The missing subcommand blocked the documented safe alternative to
`c2c sweep`, which is explicitly dangerous while managed outer loops are
running.
