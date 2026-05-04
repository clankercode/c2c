# #491 codex_resume_target — findings (F1)

**Date**: 2026-04-30
**Agent**: jungle-coder (reviewing subagent's work)
**Status**: Fix committed (`f29cda65`), cherry-picked to master (`67359d97`)

## Problem

`cmd_reset_thread` stores a thread ID in `instance_config.codex_resume_target`, but `c2c restart` was not passing it through to `prepare_launch_args`.

## Root Cause

In `cmd_start`'s resume path, the `codex_target` match (lines 4871-4876):

```ocaml
let codex_target =
  match client, session_id_override with
  | "codex", Some sid -> Some sid
  | "codex", None -> ex.codex_resume_target
  | _, _ -> ex.codex_resume_target  (* BUG: wrong for non-codex clients *)
in
```

The `| _, _` catchall returned `ex.codex_resume_target` even for non-codex clients (`opencode`, `kimi`, `claude`). This is incorrect — those clients have their own session ID systems and should get `None` when there's no explicit `session_id_override`.

## Fix

```ocaml
| _, Some _ -> ex.codex_resume_target  (* explicit session override — pass through *)
| _ -> None                            (* non-codex, no override — correct *)
```

The `codex_resume_target` now correctly flows through `run_outer_loop` → `prepare_launch_args` → `CodexAdapter.build_start_args`, so the codex adapter receives the thread ID and uses it in preference to `resume_session_id`.

## Impact

`cmd_reset_thread → c2c restart` cycle now works correctly for codex: thread ID is written to config, restart reconstructs the session, adapter resumes the correct thread.

## F2 + F3 (open)

- **F2**: Verify `codex_resume_target` is correctly passed when `c2c start codex` is called without `--session-id` but the instance has a previously-stored thread ID
- **F3**: Test `codex-headless` resume path separately (uses `thread_id_fd` mechanism, different from codex TUI)

## Verification

- `test_cmd_reset_thread_persists_codex_resume_target`: PASS
- All 155 c2c_start tests: PASS
- Build: clean (warnings same as origin/master)
- Pre-existing memory test failures: unchanged

## Commit

```
f29cda65 fix(c2c-start #491): wire codex_resume_target through cmd_restart path
cherry-picked to master: 67359d97
```