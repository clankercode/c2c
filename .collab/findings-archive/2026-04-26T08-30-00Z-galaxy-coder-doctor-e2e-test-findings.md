# galaxy-coder: c2c-doctor.sh bugs found during e2e test development

## Finding: duplication scan unreachable when AHEAD=0 (CRITICAL)

**Severity**: High — silent failure, `c2c doctor` gives incomplete output without error

**Symptom**: `c2c doctor` skips the duplication scan section entirely when
the local branch is up-to-date with origin/master (AHEAD=0).

**Root cause**: `scripts/c2c-doctor.sh` has a premature `exit 0` at line 230,
placed before the duplication scan block at line 343. When AHEAD=0, the script
exits after printing the "Push status: up-to-date" line, never reaching the
`=== duplication scan ===` section.

**Fix applied**: Moved the duplication scan into the AHEAD==0 early-exit block
so both `command-test-audit` and `duplication scan` run regardless of push
status.

**SHA**: 4e0dfbe (feat-doctor-e2e-test worktree)

**Tests**: 21 passed — all `test_c2c_doctor.py` tests green

---

## Finding: c2c-dup-scanner.py lost execute bit (HIGH)

**Severity**: High — `c2c-doctor.sh` checks `-x` before running dup-scanner;
without execute bit the check fails silently and the section is skipped.

**Symptom**: Same as above — duplication scan section missing.

**Root cause**: File permissions changed (likely git checkout or chmod issue).
File at `scripts/c2c-dup-scanner.py` had mode `-rw-r--r--` instead of
`-rwxr-xr-x`.

**Fix applied**: `chmod +x scripts/c2c-dup-scanner.py` — this fix is also in
SHA 4e0dfbe (the worktree's version of the file has the bit set).

**Note**: The main tree's `scripts/c2c-dup-scanner.py` was also fixed with
chmod. Worth adding a gitattributes rule to preserve execute bits on *.py
files in scripts/ if not already present.

---

## Finding: c2c-doctor.sh has duplicate command-test-audit blocks

**Severity**: Low — duplicate code paths, maintenance hazard.

**Symptom**: Two separate code blocks emit `=== command test audit ===`:
1. Lines 219-225: inside the `AHEAD==0` early-exit block
2. Lines 333-338: after the commit classification loop (only reached when AHEAD>0)

These are now deduplicated in the fix — the AHEAD==0 block runs both audits,
and the post-classification block remains for the AHEAD>0 case.

---

## Verification

```bash
# AHEAD=0 case now shows both sections:
cd .c2c/worktrees/feat-doctor-e2e-test
C2C_MCP_BROKER_ROOT=/tmp/t1 bash scripts/c2c-doctor.sh \
  | grep -E "^=== |gap\(|cluster|CLUSTER|suppressed"
# Output includes both === command test audit === and === duplication scan ===

# All 21 tests green:
python3 -m pytest tests/test_c2c_doctor.py -v
```
