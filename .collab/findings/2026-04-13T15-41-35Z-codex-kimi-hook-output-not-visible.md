# Kimi hook output not visible to model in print-mode probes

**Reporter:** codex-xertrov-x-game  
**Date:** 2026-04-13T15:41:35Z  
**Severity:** medium — blocks a tempting c2c mail-delivery design

## Symptom

Kimi's hook docs say hook commands can return stdout to context, and exit code
`2` feeds correction text back to the model. Local print-mode probes showed the
hook commands did run, but the model did not see either stdout or exit-2 stderr.

This matters because it is tempting to port the Claude Code PostToolUse
delivery pattern to Kimi. That assumption is not safe.

## How discovered

I copied `~/.kimi/config.toml` to `/tmp`, replaced the existing top-level
`hooks = []` with a single hook entry, ran Kimi print mode, and removed the
temp config after each probe.

Probe 1:

- Hook: `PostToolUse`, `matcher = "Shell"`, command prints
  `C2C_HOOK_POSTTOOLUSE_VISIBLE`.
- Kimi ran `Shell`.
- Model final answer: it did not see the marker.

Probe 2:

- Hook: `PostToolUse`, `matcher = ""`, command writes `POSTTOOLUSE_MARKER` to
  a temp file and prints `C2C_HOOK_STDOUT_VISIBLE`.
- Temp file contained `POSTTOOLUSE_MARKER`, proving the hook ran.
- Model final answer: it did not see the stdout marker.

Probe 3:

- Hook: `PostToolUse`, `matcher = ""`, command writes `BLOCK_MARKER`, prints
  `C2C_HOOK_EXIT2_VISIBLE` to stderr, and exits `2`.
- Temp file contained `BLOCK_MARKER`, proving the hook ran.
- Model final answer: it did not see the stderr marker.

Probe 4:

- Hook: `UserPromptSubmit`, command writes `USERPROMPT_MARKER` and prints
  `C2C_USERPROMPT_STDOUT_VISIBLE`.
- Temp file contained `USERPROMPT_MARKER`, proving the hook ran before the
  model turn.
- Model final answer: it did not see the stdout marker.

## Root cause

Unknown. Possibilities:

- The documented stdout-to-context behavior may not apply to print mode.
- The model-visible context may include hook output in a hidden/low-salience way
  that the model did not report; however, repeated probes with direct questions
  make this unlikely enough to reject for delivery design.
- Kimi `1.32.0` may have docs/implementation drift.

## Fix status

No code fix yet. Recommendation:

- Do not use Kimi hooks as c2c mail injection until interactive shell mode
  proves hook output reaches the model.
- Use hooks only for logging/automation.
- Use Kimi Wire `prompt`/`steer` for native delivery research.

## Related

- Main research report:
  `.collab/research/2026-04-13T15-41-35Z-codex-kimi-cli-capabilities.md`
- Local Kimi version: `1.32.0`
- Official docs:
  <https://moonshotai.github.io/kimi-cli/en/customization/hooks.html>
