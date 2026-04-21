# Crush One-Shot Blocked by Missing ANTHROPIC_API_KEY

## Symptom

Attempting to run `crush run <prompt>` to prove a Crush MCP DM smoke
fails immediately with:

```
ERROR

  No providers configured - please run 'crush' to set up a provider interactively.
```

## Root Cause

Crush resolves `api_key` from its `providers.json` as `$ANTHROPIC_API_KEY`.
The shell environment Claude Code runs in does not have `ANTHROPIC_API_KEY`
set (Claude Code doesn't need it — the model is provided by the host).
Without the env var, Crush treats Anthropic as unconfigured.

## What Was Tried

1. `XDG_CONFIG_HOME=/tmp/crush-smoke-config crush run ...` — overrides config
   dir. Data dir still resolves to `~/.local/share/crush` where providers.json
   lives, but the env var is still missing at crush's runtime.

2. Copying providers.json into the temp config dir — no effect.

3. `crush run --data-dir ~/.local/share/crush ...` — same result.

Crush reads `$ANTHROPIC_API_KEY` from the environment at startup, not
from a stored credential, so no config-dir hack can work around this.

## Impact

- Crush one-shot DM smoke (like Kimi's `--print` proof) cannot be run from
  inside a Claude Code session.
- A live Crush session started by the user with `ANTHROPIC_API_KEY` in their
  shell will work fine — the c2c MCP config is correct.
- The `crush run` approach is only viable if the user exports `ANTHROPIC_API_KEY`
  before invoking, or runs the smoke manually in their own shell.

## Severity

Low — Crush DM works, just can't be automated from the Claude Code shell.
The `c2c setup crush` config is correct (now includes `C2C_MCP_SESSION_ID`
after commit `1f6e73a`). A human can prove the roundtrip by running:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
crush run --quiet --cwd /path/to/c2c-msg \
  "Using the c2c MCP server tools: call whoami, then send_room to swarm-lounge."
```

## Fix Status

- **c2c side**: no fix needed — config is correct.
- **Proof gap**: Crush MCP DM roundtrip remains unproven from automation.
  Mark as ~ in the matrix until a human validates it.
