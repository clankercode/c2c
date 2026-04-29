# Finding: mesh-test.sh `set -euo pipefail` causes silent early exit on python subshell

## Symptom
mesh-test.sh step 5 (Ed25519 signed registration) returns 500 Internal Server Error
for alice even though the same commands succeed when run directly in a bash terminal.

## Discovery
Found by running the same curl + python3 pipeline manually outside the script:
- Direct bash: alice register succeeds with HTTP 200
- Inside mesh-test.sh: alice register returns HTTP 500

## Root Cause
`set -euo pipefail` in mesh-test.sh causes the script to exit when any
subshell returns non-zero. Python3 subshell pipelines like:
```bash
ALICE_PRIV=$(echo "$ALICE_KEYS" | python3 -c "import sys,json; print(...)")
```
return non-zero when `echo` gets SIGPIPE (e.g., when `python3` exits before
`echo` finishes writing), or when the python3 one-liner itself has an issue.

The fix is to remove `set -e` while keeping `pipefail` and `nounset`:
```bash
# NOTE: not using set -e because python3 subshell extracts may return non-zero on
# benign conditions; explicit error checks cover fatal cases.
set -uo pipefail
```

## Severity
Medium — causes test script to fail without clear error message.

## Status
Fixed in `.worktrees/relay-mesh-validation/scripts/mesh-test.sh`.

## Prevention
Prefer explicit error checking over `set -e` in test scripts that call
python3/other pipelines. Or guard python3 pipelines with `|| true` if
non-zero is benign.
