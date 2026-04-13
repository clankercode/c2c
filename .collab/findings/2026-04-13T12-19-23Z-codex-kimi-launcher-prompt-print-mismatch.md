# Kimi managed launcher prompt/print mismatch

- **Symptom:** `run-kimi-inst` launched configured Kimi instances in one-shot print mode whenever the config contained `prompt`.
- **How discovered:** Max reported a detached Kimi process and asked whether the managed launcher lined up with the Kimi CLI for interactive mode. `kimi --help` on Kimi CLI 1.31.0 shows `--prompt` and `--print` are independent flags; `RUN_KIMI_INST_DRY_RUN=1 ./run-kimi-inst kimi-nova` showed the wrapper emitted `kimi --yolo --print --prompt ...`.
- **Root cause:** The wrapper encoded `prompt` as "non-interactive print prompt" instead of "initial prompt". That was inconsistent with the current CLI, where `--print` is the explicit non-interactive mode.
- **Fix status:** Fixed in this session by making `prompt` pass `--prompt` while staying interactive, and adding explicit config `"print": true` for one-shot runs.
- **Severity:** Medium. It made managed Kimi sessions detach from the expected interactive frontend and made Ctrl-C/job-control behavior confusing.
