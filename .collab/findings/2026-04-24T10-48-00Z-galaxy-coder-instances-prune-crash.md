# c2c instances --prune-older-than crashes on broken client.log symlinks

**Reporter**: galaxy-coder
**Date**: 2026-04-24T10:43 UTC
**Severity**: medium — crashes prune on instances with broken client.log symlinks

## Symptom

`c2c instances --prune-older-than 0` throws an uncaught exception:
```
c2c: internal error, uncaught exception:
     Sys_error("/home/xertrov/.local/share/c2c/instances/ceo/client.log: No such file or directory")
```

The error occurs when pruning instances whose `client.log` symlink points to a non-existent target (broken symlink). The exception is `Sys_error` which indicates an `open_in` failure, NOT a `Sys.remove` failure.

## Affected instances

- `ceo` — opencode instance, `client.log` is symlink to non-existent log file
- `boot-val-1776765030` — same pattern
- Both have `oc-plugin-state.json` but no `config.json`

## Observations

1. `c2c instances` (without `--prune-older-than`) works fine — no crash
2. The error is an `open_in` failure, not a `Sys.remove` failure
3. Instances without `config.json` are still being processed (they have `client = "?"`)
4. The error message says `client.log`, suggesting some code path is trying to read this file

## Root cause

Unknown. Suspected locations:
1. `rm_rf` in prune path — but `rm_rf` uses `Sys.remove`, not `open_in`
2. Some JSON reading code in the prune/diag path
3. A cleanup/finalizer that's triggered during exception handling

## Workaround

Run `c2c instances` without `--prune-older-than` to list instances safely.

## Next steps

- Find where `open_in` is being called on `client.log` in the prune code path
- Check if instances without `config.json` should be filtered out earlier
- Verify `rm_rf` handles broken symlinks correctly (should use `Sys.remove` which calls `unlink()`)
