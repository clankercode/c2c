# c2c start --bin cc-mm Session Resume Failure

## Symptom
`c2c start claude -n dev-ceo --bin cc-mm` fails with "No conversation found with session ID: 5f288a81-e5e2-48da-96da-3680ee076a6a"

## Root Cause
**Dual issue:**

1. **Args override**: `c2c start --bin cc-mm` was passing `start dev-ceo --resume <sid> --name dev-ceo` as launch args. But `cc-mm` just forwards ALL args to `claude` via `exec claude "$@"`. So `claude` received `start dev-ceo --resume <sid> --name dev-ceo` as arguments.

2. **`claude` interprets args as prompt**: `claude` treats:
   - `start dev-ceo` as a prompt text (starts interactive chat with that text)
   - `--name dev-ceo` as a prompt too (not a session identifier)

   So `--resume <sid>` was passed but with `dev-ceo` as the prompt, and the session was never properly resumed.

3. **Session never existed**: Because the original `cc-mm start dev-ceo` didn't create a proper named session - it started `claude` with prompt "start dev-ceo". The stored `resume_session_id: 5f288a81...` was never associated with any actual session.

## Technical Details

**`cc-mm` wrapper behavior:**
```bash
cc-mm start dev-ceo  # → cc_run mm start dev-ceo → exec clauclaude start dev-ceo
```
`cc-mm` passes ALL arguments to `claude`. `claude start dev-ceo` means "chat with prompt 'start dev-ceo'", not "manage a session named dev-ceo".

**Session discovery:**
- Session files stored at `~/.claude-shared/sessions/<PID>.json`
- Files named by PID (not session UUID)
- Session UUID inside file JSON (`sessionId` field)
- `5f288a81...` UUID never found in any session file

## Fix Applied
Modified `c2c_start.ml` to detect `cc-` wrapper scripts and invoke them directly without extra args.

**Changes:**
1. Added `is_cc_wrapper` helper function (line 352-357)
2. Modified `run_outer_loop` to use empty launch args for cc- wrappers (line 489-500)

**Result:**
- `c2c start --bin cc-mm` now invokes `cc-mm` directly (no args)
- `cc-mm` starts an interactive Claude Code session with the `mm` profile
- Session management is handled by the wrapper directly

## Files Modified
- `ocaml/c2c_start.ml`: Added `is_cc_wrapper` detection and special-case handling

## Severity
**Medium** - Prevents using profile wrappers (`cc-mm`, `cc-w`, etc.) with `c2c start`