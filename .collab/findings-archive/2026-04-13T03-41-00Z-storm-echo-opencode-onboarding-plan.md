# OpenCode c2c onboarding plan

**Author:** storm-echo / c2c-r2-b1
**Date:** 2026-04-13
**Status:** plan; no live config changes made in this turn.

## Goal

Let an OpenCode session running in this repo participate in c2c as a
first-class peer, receiving and sending through the same broker
registry used by Claude and Codex. Closes task-list item #4 "Prep
opencode MCP config for c2c-impl-gpt onboarding" and moves task #3
"Loop in c2c-impl-gpt (OpenCode)" closer to actionable.

## Current state

- OpenCode is installed at `~/.bun/bin/opencode`, config at
  `~/.config/opencode/opencode.json`. Config format already has an
  `mcp` key with `local` and `remote` variants.
- Sample local-MCP entry from the existing config:
  ```
  "patent-tools": {
    "type": "local",
    "command": ["/home/xertrov/.cargo/bin/patent-mcp-server"]
  }
  ```
- Claude uses project-local `.mcp.json` at the repo root, with
  `mcpServers.c2c`:
  ```
  {
    "mcpServers": {
      "c2c": {
        "type": "stdio",
        "command": "python3",
        "args": ["/home/xertrov/src/c2c-msg/c2c_mcp.py"],
        "env": {
          "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c-msg/.git/c2c/mcp"
        }
      }
    }
  }
  ```
- Codex already runs as a c2c participant via `run-codex-inst-outer`,
  broker alias `codex`, broker session `codex-local`, using the MCP
  server in its own process.

## Proposed OpenCode stanza

The minimal translation into `~/.config/opencode/opencode.json` under
the top-level `mcp` key is:

```
"c2c": {
  "type": "local",
  "command": [
    "python3",
    "/home/xertrov/src/c2c-msg/c2c_mcp.py"
  ],
  "environment": {
    "C2C_MCP_BROKER_ROOT": "/home/xertrov/src/c2c-msg/.git/c2c/mcp",
    "C2C_MCP_SESSION_ID": "opencode-local",
    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0"
  }
}
```

Unknowns (resolve before landing):
- OpenCode may call the env key `env` (like Claude/MCP spec) rather
  than `environment`. Verify with `opencode mcp add --help` or by
  reading `~/.config/opencode/node_modules/.../schema.json`.
- OpenCode may not support `type: local` for stdio MCP servers in
  the same way Claude does. `opencode mcp add` is the supported flow:
  `opencode mcp add c2c --local "python3 /home/xertrov/src/c2c-msg/c2c_mcp.py"`.
- Whether `C2C_MCP_AUTO_DRAIN_CHANNEL=0` is actually necessary for
  OpenCode — it may just ignore `notifications/claude/channel`
  entirely, in which case the env gate is harmless. Setting it is
  safer while we don't know.

Session identity: use `C2C_MCP_SESSION_ID="opencode-local"` so the
OpenCode broker peer appears in the registry as a single stable
entry, mirroring how Codex appears as `codex-local`. Alias
registration is then done by the OpenCode session itself at startup
via `mcp__c2c__register("c2c-impl-gpt")` (or whatever alias the
session chooses).

## Onboarding script sketch

Analogue of `run-codex-inst` / `run-claude-inst-outer` for OpenCode:
- Wrap the OpenCode launch with a pidfile so `restart-self` can
  SIGTERM it cleanly.
- Pin session identity by setting `C2C_MCP_SESSION_ID` in the env.
- Pass an equivalent kickoff prompt via `opencode run`, reusing the
  same "Orient and advance the active goal" framing that the Claude
  and Codex launchers already use.

Rough shape:
```
#!/usr/bin/env bash
set -euo pipefail
export C2C_MCP_SESSION_ID="opencode-local"
export C2C_MCP_BROKER_ROOT="/home/xertrov/src/c2c-msg/.git/c2c/mcp"
export C2C_MCP_AUTO_DRAIN_CHANNEL="0"
echo $$ > run-opencode-inst.d/c2c-opencode-b1.pid
exec opencode run \
  "Session resumed as the OpenCode C2C participant for c2c-msg. \
   First call mcp__c2c__poll_inbox as alias c2c-impl-gpt, handle any \
   queued messages, re-register if missing, skim .collab/updates and \
   tmp_collab_lock.md for peer activity, read .goal-loops/active-goal.md, \
   then pick the highest-leverage unblocked next action."
```

`opencode run` is the non-TUI invocation that takes a single message
and runs to completion — matches the `codex resume` pattern rather
than the `claude --resume` pattern. Whether it re-enters the same
session across invocations is still to verify; if not, the
persistent-session story for OpenCode is different from the
Claude/Codex one and we may need `opencode serve` + `opencode attach`
or `opencode acp` instead.

## Out of scope for this plan

- **Editing opencode.json live.** That file contains third-party API
  credentials for unrelated MCP servers (web-search-prime and
  web-reader Z.AI bearer tokens). I deliberately did not copy or
  modify it this turn — any live edit should be done by an operator
  who can review the diff against the secret surface. A cleaner path
  is `opencode mcp add c2c --local ...` which only touches the one
  key.
- Actually launching an OpenCode session in this repo. Needs Max's
  go-ahead because it spawns a new agent in the swarm.
- OpenCode quota / auth handling — the running OpenCode install is
  wired into github-copilot as provider and I should not burn tokens
  probing it.

## Suggested next step for the swarm

Someone (probably an operator or a session with explicit Max go-ahead)
runs:

```
opencode mcp add c2c --local \
  "python3 /home/xertrov/src/c2c-msg/c2c_mcp.py"
```

...confirms the c2c tools show up via `opencode mcp list`, then
launches one OpenCode session in this repo to test the end-to-end
round trip — `mcp__c2c__register` + `mcp__c2c__send` to `storm-echo`
+ `mcp__c2c__poll_inbox` on the OpenCode side to confirm inbound
delivery also works. That's the c2c-impl-gpt onboarding proof.

After the proof, `run-opencode-inst-outer` can be built off the same
shape as the Claude and Codex launchers for unattended auto-resume.
