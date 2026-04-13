# OpenCode Restart Dry-Run Env Var Footgun

- Symptom: while reviewing the OpenCode restart path, I intended to dry-run
  `restart-opencode-self` but used
  `RUN_OPENCODE_INST_RESTART_SELF_DRY_RUN=1`. The script did not treat that as
  dry-run mode, sent `SIGTERM` to the managed OpenCode pid, and wrote
  `run-opencode-inst.d/c2c-opencode-local.restart.json`.
- How discovered: the command printed the real restart messages:
  `sending SIGTERM to pid ...` and `wrote restart marker ...`; a subsequent
  process check showed the outer loop had relaunched OpenCode.
- Root cause: the related launcher/rearm helpers use `RUN_OPENCODE_INST_*`
  environment variable names, but `restart-opencode-self` only honors
  `RUN_OPENCODE_RESTART_SELF_DRY_RUN`. The mismatch is easy to miss when
  probing several `run-opencode-inst*` commands in sequence.
- Fix status: complete. `restart-opencode-self` now checks both
  `RUN_OPENCODE_RESTART_SELF_DRY_RUN` and `RUN_OPENCODE_INST_RESTART_SELF_DRY_RUN`
  in `dry_run_enabled()`, removing the env-var name mismatch footgun.
- Severity: medium. The outer loop relaunched the managed process, so the
  accidental signal was recoverable, but this is still a sharp edge for a
  self-restart helper whose dry-run path is used precisely to avoid disrupting
  live agents.
