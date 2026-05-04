# Finding: `c2c doctor` hangs due to `c2c-dup-scanner.py` ThreadPoolExecutor + O(n²) cluster (#519)

**Filed**: 2026-05-01T18:15:00Z
**Severity**: MEDIUM (c2c doctor unusable; affects dev workflow)
**Agent**: cedar-coder
**Status**: Root cause confirmed; fix not yet implemented

## Symptom
`c2c doctor` hangs indefinitely, appearing to freeze for 2+ minutes before Max had to `pkill` it. `c2c doctor --json` also hangs.

## Discovery
- `c2c health` alone: ~1.1s (fast)
- `c2c doctor` full: hangs (~30s+ before timeout kill)
- `scripts/c2c-dup-scanner.py --repo /home/xertrov/src/c2c --summary --warn-only`: hangs immediately, no output before 3s timeout kill
- File discovery: finds 9342 `.py/.ml/.mli` files in <5s (fast)
- The hang occurs during the ThreadPoolExecutor parallel scan + `find_clusters` O(n²) processing

## Root Cause
`c2c-dup-scanner.py` uses `ThreadPoolExecutor` to scan all discovered files, then runs `find_clusters` which is O(n²) in the number of token windows. With 9342 files, each potentially thousands of windows, this creates an unbounded computational load that appears as an infinite hang.

`c2c doctor` calls it as:
```bash
"$SCRIPT_DIR/c2c-dup-scanner.py" --repo "$PWD" --full --warn-only || true
```
The `|| true` means it silently times out without failing the doctor rollup.

## Fix Options
1. **Quick-fix (in scanner)**: Add `--max-files N` cap (default 500) to limit parallelism; add a `concurrent.futures.wait()` with timeout inside the ThreadPoolExecutor loop
2. **Quick-fix (in doctor wrapper)**: Run dup-scanner with a hard 30s timeout in `c2c-doctor.sh`
3. **Proper-fix**: Rewrite `find_clusters` with a hash-based dedup instead of O(n²) comparison

## Test Fix
After fix: `timeout 30 c2c doctor` should complete without hanging.

## Related
- `scripts/c2c-doctor.sh` line 296: the `--full` flag triggers full duplication analysis
