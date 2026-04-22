# c2c_tmux.py launch --extra quoting issue

**Date**: 2026-04-23
**Found by**: Lyra-Quill
**Status**: Confirmed — minor UX issue

## Symptom

Launching `c2c start opencode --agent gui-tester` via `c2c_tmux.py launch`
fails with:
```
c2c: unknown option --agent gui-tester. Did you mean -a?
```

## Root Cause

The `c2c_tmux.py launch` script passes `--extra` args directly to `c2c start`.
When the user passes `--extra "--agent gui-tester"` with double quotes around
`--agent gui-tester`, those quotes are preserved and the whole string
`--agent gui-tester` is treated as a single argv element — not as `--agent`
with value `gui-tester`.

## Reproduction

```bash
# FAILS — quotes preserved
python3 scripts/c2c_tmux.py launch opencode -n test --new-window \
  --extra "--agent gui-tester"

# WORKS — equals syntax avoids quoting issue
python3 scripts/c2c_tmux.py launch opencode -n test --new-window \
  --extra "--agent=gui-tester"

# ALSO WORKS — space without extra quotes (shell splits correctly)
python3 scripts/c2c_tmux.py launch opencode -n test --new-window \
  --extra "-a" --extra "gui-tester"
```

## Impact

Low — the launch script is a convenience wrapper. Direct `c2c start` CLI
works correctly with all three value syntaxes (`-a foo`, `--agent foo`,
`--agent=foo`). The `c2c_tmux.py` script just needs to split `--extra`
arguments on spaces before passing to the subprocess, or document that users
should use `--agent=foo` syntax with `--extra`.

## Fix options

1. **Doc fix** (quick): document that `--extra` values with spaces should use
   equals syntax: `--extra "--agent=my-role"` instead of `--extra "--agent my-role"`
2. **Code fix**: `c2c_tmux.py launch` splits `--extra` arguments on whitespace
   before appending to argv (more idiomatic)
3. **Both**: doc fix now, code fix later

## Filed by

Lyra-Quill 2026-04-23