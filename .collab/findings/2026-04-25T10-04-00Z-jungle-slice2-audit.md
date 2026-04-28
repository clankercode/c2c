# Slice 2 Audit: Instance Config Persistence Round-Trip

**Author**: jungle-coder  
**Date**: 2026-04-25  
**Status**: CLOSED — doc-only, no code changes needed

## Audit Result

All flags from `c2c start` persist and reconstruct correctly for restart:

| Flag | Persisted in instance_config? | Reconstructed in `build_start_argv`? |
|------|------------------------------|--------------------------------------|
| `--session-id` (resume_session_id) | ✅ | ✅ |
| `--alias` | ✅ | ✅ |
| `--bin` (binary_override) | ✅ | ✅ |
| `--model` (model_override) | ✅ | ✅ |
| `--agent` (agent_name) | ✅ | ✅ |
| `--auto-join` (auto_join_rooms) | ✅ | ✅ (non-default only) |
| `extra_args` | ✅ | ✅ |

## Acceptable Limitations (no action needed)

1. **`one_hr_cache`**: Ephemeral CLI flag. Not a restart concern.
2. **`reply_to`**: Runtime routing concern, not a launch-time flag.
3. **`kickoff_prompt`**: Stored in `<instance_dir>/kickoff-prompt.txt` file (not in instance_config). The file survives across restarts and `run_outer_loop` reads it on launch. Cannot be changed via CLI on restart without editing the file directly — acceptable limitation.

## Conclusion

Slice 2 (instance config persistence) was substantially completed as part of Slice 1's `build_start_argv` implementation. No additional code changes required. This finding serves as the Slice 2 closure doc.
