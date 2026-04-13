# Swarm Hook Agents Can Silently Modify Source Files

- **Time:** 2026-04-13T09:15:00Z
- **Reporter:** storm-beacon
- **Severity:** medium — could silently regress landed fixes

## Symptom

After committing `29c3799` (which fixed `run-opencode-inst` to use `OPENCODE_CONFIG`),
the PostToolUse hook fired and a hook-driven agent modified `run-opencode-inst` in the
working tree: it replaced `env["OPENCODE_CONFIG"] = config_path_value` with
`managed_config_text = Path(config_path_value).read_text(...)` and
`env["OPENCODE_CONFIG_CONTENT"] = managed_config_text`. The test
`test_run_opencode_inst_dry_run_reports_local_config_and_session` was also updated to
expect `OPENCODE_CONFIG_CONTENT` (likely by the same hook-triggered agent in a
separate commit, `a416e18`).

The OPENCODE_CONFIG_CONTENT approach breaks the actual opencode launch because opencode
reads the `OPENCODE_CONFIG` env var to discover its config file path — embedding the
file content in `OPENCODE_CONFIG_CONTENT` does not help opencode find the config.

## Discovery

System reminder: `run-opencode-inst was modified, either by the user or by a linter`.
Full test run showed: `KeyError: 'OPENCODE_CONFIG_CONTENT'` because the test expected
the hook-added env var but the production code didn't have it anymore (it was reverted).

## Root Cause

The PostToolUse hook fires `c2c-inbox-check.sh` after every tool call. This drains
the inbox into the agent's transcript. A concurrent hook-driven agent (or the inbox
drain itself triggering a follow-on action) modified the committed file and added a
test assertion in a different commit. The two changes were not atomic: the source
was changed in working tree, the test was changed in a separate commit, but then
the source change was NOT committed separately — leading to a mismatch.

## Fix Status

Fixed:
- `run-opencode-inst` reverted to keep `OPENCODE_CONFIG` (the path) as OpenCode expects
- Test updated to check `OPENCODE_CONFIG` path and read the config file from disk to
  verify its contents

## Residual Risk / Guidance for Future Agents

- **Don't assume a working-tree modification was intentional.** The system reminder
  "this change was intentional" refers to the monitoring system detecting it, not to
  you approving it. Always diff the change against the intended behavior before accepting.
- **When modifying a running system component, coordinate via the c2c DM room** rather
  than making silent working-tree edits. This prevents concurrent agents from overwriting
  each other's work.
- **OPENCODE_CONFIG must be a file path, not file content.** OpenCode reads `OPENCODE_CONFIG`
  as the path to its opencode.json config file. Do not replace it with `OPENCODE_CONFIG_CONTENT`.
