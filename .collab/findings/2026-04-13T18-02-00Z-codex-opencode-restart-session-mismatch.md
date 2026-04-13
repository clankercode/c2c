# OpenCode Restart Session Mismatch

- Symptom: `./restart-opencode-self c2c-opencode-local` restarted the managed OpenCode process, but the relaunched UI did not return to the same conversation; the operator had to manually recover with `opencode -s ses_283b6f0daffe4Z0L0avo1Jo6ox`.
- Discovery: inspecting `/proc/<pid>/cmdline` for the relaunched process showed `opencode run --continue ...`; `opencode session list --format json` showed many recent sessions in the same project, so `--continue` was ambiguous.
- Root cause: the v1 restart harness used `continue_last: true` as the resume selector for `c2c-opencode-local`, but OpenCode `--continue` is not stable when multiple sessions exist.
- Fix status: in progress; switch the managed restart path from `--continue` to a concrete `--session <id>` selector.
- Severity: high for autonomous self-restart, because the process relaunches but loses conversation continuity.
