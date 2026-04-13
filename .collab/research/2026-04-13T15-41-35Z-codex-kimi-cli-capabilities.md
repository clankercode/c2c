# Kimi Code CLI capabilities for c2c

**Researcher:** codex-xertrov-x-game
**Date:** 2026-04-13T15:41:35Z
**Local Kimi version tested:** `kimi, version 1.32.0`
**Package state checked:** PyPI lists `kimi-cli` `1.33.0` as available

## Executive summary

Kimi is MCP-first and already good enough for correct c2c send/poll/room
behavior. The repo has live proof that Kimi can load the c2c MCP server, call
`whoami`, `send`, `send_room`, `poll_inbox`, receive a direct DM while alive,
and reply over the broker.

The unsolved problem is reliable **mail injection into an idle Kimi session**.
Kimi now has beta hooks and beta plugins, but neither is an OpenCode-style
runtime plugin that can call "append this as a user turn" inside an existing
TUI. Hooks do run locally, but in print-mode probes their stdout and exit-2
stderr were not visible to the next model step. Plugins add agent-callable
tools, not background delivery.

The best long-term path is a Kimi Wire wrapper:

1. Start Kimi with `kimi --wire`.
2. Watch the c2c broker inbox with inotify/polling.
3. When idle, send Wire `prompt` with the c2c envelope.
4. During an active turn, use Wire `steer` to inject after the current step.
5. Keep MCP as the tool path and fallback poll surface.

PTY/direct-PTS wake remains useful as an operator fallback, but recent repo
findings show it is not a reliable correctness layer for idle Kimi.

## Capability matrix

| Surface | Kimi capability | c2c implication |
|---|---|---|
| MCP | First-party MCP client, `~/.kimi/mcp.json`, `kimi mcp add/list/remove/auth/test`, `--mcp-config-file`, `--mcp-config`. | Keep c2c setup as stdio MCP in `~/.kimi/mcp.json`. This is the guaranteed baseline. |
| MCP auto-approval | Broad `--yolo` / `--yes` / `--auto-approve`; print mode implicitly enables yolo. I found no documented per-MCP-tool allowlist like Codex. | Use yolo only for managed swarm/test sessions. Manual Kimi should still work with approval prompts, but unattended c2c needs yolo or an approval-handling Wire client. |
| Plugins | Beta plugin dirs with `plugin.json`; tools are subprocess commands that receive JSON on stdin and return stdout. | Can package c2c convenience tools, but MCP is better for the broker because c2c already has a persistent MCP server and tool schemas. Plugins are not background mail delivery. |
| Hooks | Beta lifecycle hooks in `~/.kimi/config.toml`; includes `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `Notification`, etc. | Useful for automation and maybe nudges, but not proven as mail injection. Local probes show hooks run, but their output did not reach model context in print mode. |
| Post-tool hook | Official docs list `PostToolUse` after successful tool execution. Local probe verified the hook command ran after `Shell`. | PostToolUse exists, but not enough for c2c delivery unless a Kimi TUI/agent mode probe proves hook output is surfaced to the model. Do not port Claude's PostToolUse delivery assumption directly. |
| Monitor-like file watch | No first-party equivalent of Claude Code's `Monitor` tool found. | Use an external watcher/daemon or Wire wrapper. Hooks only trigger inside Kimi lifecycle events. |
| Wire mode | Official JSON-RPC 2.0 protocol over stdin/stdout. Supports `initialize`, `prompt`, `steer`, `set_plan_mode`, `cancel`, events, approval requests, external tools, and hook subscriptions. | Best native delivery path. It gives us a structured "mail injection" surface without terminal hacks. |
| ACP | `kimi acp` / deprecated `--acp` exists; terminal/Web/IDE integrations use agent protocols. | ACP may be useful later, but Wire is lower-level and explicitly exposes prompt/steer, so it is the better first target. |
| Print mode | `--print`, stream-json input/output, final-message-only, documented exit codes. Auto-yolo. | Excellent for smoke tests and one-shot agents. Avoid using inherited c2c env; always pass temp MCP config/session IDs. |
| Session data | `~/.kimi/sessions/<work-dir-hash>/<session-id>/{context.jsonl,wire.jsonl,state.json}` and logs under `~/.kimi/logs/kimi.log`. | Useful for postmortems and replay, but not a delivery API. |

## What the repo already does

Claude, Codex, and OpenCode provide the comparison set:

- Claude setup writes MCP into `~/.claude.json` and a PostToolUse hook into
  `~/.claude/settings.json` via `c2c_configure_claude_code.py`.
- Codex setup writes `~/.codex/config.toml` with all c2c MCP tools
  auto-approved via `c2c_configure_codex.py`.
- OpenCode setup writes `.opencode/opencode.json`, installs
  `.opencode/plugins/c2c.ts`, and uses `client.session.promptAsync` to deliver
  broker messages as native user turns.
- Kimi setup currently writes `~/.kimi/mcp.json` via
  `c2c_configure_kimi.py`.
- `run-kimi-inst` sets `C2C_MCP_SESSION_ID`, `C2C_MCP_AUTO_REGISTER_ALIAS`,
  `C2C_MCP_CLIENT_PID`, `KIMI_CLI_NO_AUTO_UPDATE`, and `--yolo`.
- `c2c_inject.py` and `c2c_deliver_inbox.py` special-case `--client kimi` to
  use direct PTS writing through `c2c_pts_inject.py`.
- `c2c_kimi_prefill.py` exists because Kimi `--prompt` is normally one-shot;
  the shim uses Kimi's internal shell prefill path for interactive launch.

The current Kimi path is therefore:

1. MCP config and tool calls: solid.
2. Managed/one-shot print smoke: solid.
3. Idle autodelivery: still weak.

## Local probes run

### MCP and command surface

Commands:

```bash
command -v kimi
kimi --version
kimi --help
kimi plugin --help
kimi plugin install --help
kimi plugin list
kimi mcp --help
kimi mcp list
kimi mcp test c2c
kimi info
python -m pip index versions kimi-cli
```

Results:

- `kimi` path: `/home/xertrov/.local/bin/kimi`
- local version: `1.32.0`
- `kimi info`: agent spec versions `1`, wire protocol `1.9`, Python `3.13.12`
- `kimi mcp list`: c2c configured in `/home/xertrov/.kimi/mcp.json`
- `kimi mcp test c2c`: connected, 16 c2c tools visible
- `kimi plugin list`: no plugins installed locally
- PyPI: `1.33.0` available

### Hook probes

I ran temp-config probes by copying `~/.kimi/config.toml` to `/tmp`, replacing
the top-level `hooks = []` with a single hook entry, and running print mode.
The temp config was removed after each probe.

Findings:

- `PostToolUse` hook with `matcher = ""` ran after `Shell`; it wrote a marker
  file.
- `PostToolUse` hook stdout was not visible to the model in the next step.
- `PostToolUse` hook with exit code `2` and stderr also was not visible to the
  model in the next step.
- `UserPromptSubmit` hook ran and wrote a marker file before the model turn.
- `UserPromptSubmit` hook stdout was not visible to the model.

This contradicts the simple reading of the hooks docs for our delivery use
case. It may be print-mode-specific, version-specific, or a docs/implementation
gap. It should be live-tested in shell mode before using hooks for c2c mail.

The dedicated finding is:

- `.collab/findings/2026-04-13T15-41-35Z-codex-kimi-hook-output-not-visible.md`

## Recommended architecture

### Tier 1: MCP baseline

Keep and harden `c2c setup kimi`:

- Write `~/.kimi/mcp.json` with `mcpServers.c2c`.
- Always include:
  - `C2C_MCP_BROKER_ROOT`
  - `C2C_MCP_SESSION_ID`
  - `C2C_MCP_AUTO_REGISTER_ALIAS`
  - `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`
  - `C2C_MCP_AUTO_DRAIN_CHANNEL=0`
  - `C2C_MCP_CLIENT_PID` when launched by a managed wrapper
- For one-shot probes, use explicit temp `C2C_MCP_SESSION_ID` and temp
  `--mcp-config-file`. Do not inherit `CLAUDE_SESSION_ID` or another client's
  c2c env.

### Tier 2: Hook-assisted polling, not delivery

Hooks can still help if used conservatively:

- `SessionStart`: remind/register/poll at startup if Kimi shell mode surfaces
  hook output in practice.
- `UserPromptSubmit`: opportunistically run a non-draining `peek_inbox` and
  maybe log or notify.
- `PostToolUse`: maintenance tasks, telemetry, stale-pid checks.
- `Notification`: desktop or log notifications for approval/background events.

Do not assume hook stdout/stderr injects c2c mail into the model. The local
print-mode probes say it does not.

### Tier 3: Wire delivery bridge

Build `c2c_kimi_wire_bridge.py` or equivalent:

- Launch `kimi --wire --work-dir <repo> --mcp-config-file <temp-c2c.json>`.
- Send `initialize` with:
  - client info
  - `supports_question=false` unless implemented
  - optional hook subscriptions for liveness/turn-state
- Track turn state from Wire events (`TurnBegin`, `TurnEnd`, `StepBegin`,
  `SteerInput`, `HookTriggered`, `HookResolved`).
- Watch `<broker-root>/<session-id>.inbox.json`.
- On queued messages:
  - if no turn active, drain through c2c CLI/MCP/file fallback, spool, then
    send Wire `prompt` with the c2c envelope.
  - if a turn is active, either wait until `TurnEnd` or send Wire `steer` with
    the envelope.
- Keep a spool until Wire `prompt`/`steer` succeeds.
- Handle approval requests if not running yolo; for managed swarm mode, yolo is
  acceptable if the c2c server is trusted.

This is the closest analogue to OpenCode's `client.session.promptAsync`, but
using Kimi's official structured protocol rather than a plugin SDK.

### Tier 4: PTY/direct-PTS fallback

Keep `c2c_pts_inject.py` and `c2c_kimi_wake_daemon.py` as a manual fallback:

- Useful for interactive Kimi shells already attached to a terminal.
- Not enough for correctness because recent findings show idle Kimi may ignore
  injected prompts.
- Never inject message bodies by PTY as the primary path. Inject only a nudge
  to call `poll_inbox`, or use Wire.

## Answering Max's specific questions

### Can we do plugins?

Yes, but Kimi plugins are not OpenCode plugins. Kimi plugins are installed
tool bundles: a directory with `plugin.json` and subprocess tools. They are
good for packaging project-specific commands, but they do not provide a
background runtime with an SDK client that can push user turns into a live
session. For c2c, MCP remains better than a Kimi plugin for `send`, `poll`,
rooms, and history.

### How do we inject mail?

Today:

- Correct baseline: tell Kimi to call `mcp__c2c__poll_inbox`.
- One-shot/managed smoke: run Kimi print mode with explicit temp MCP config and
  prompt it to poll/reply.
- Fallback TUI wake: direct PTS/PTY nudge, but not reliable enough for idle
  delivery.

Recommended:

- Wire bridge: external watcher drains/spools c2c mail and injects via Wire
  `prompt` when idle or `steer` during an active turn.

Not recommended:

- Writing Kimi session JSONL files directly.
- Relying on hook stdout as the delivery channel.
- Relying on PTY body injection.

### Does post tool call work?

`PostToolUse` exists and the hook command ran in a local probe. However, the
model did not see the hook stdout or exit-2 stderr in print mode. Treat
PostToolUse as usable for automation/logging, not proven for mail injection.

### Is there a Monitor tool similar to Claude?

No first-party Kimi Monitor equivalent was found. Kimi has hooks and background
task notifications, but not an arbitrary file-watch tool that wakes the agent
when `.git/c2c/mcp/*.inbox.json` changes. Use an external watcher or Wire
wrapper.

## Sources

- Kimi docs entry: <https://moonshotai.github.io/kimi-cli/en/>
- Kimi command reference: <https://moonshotai.github.io/kimi-cli/en/reference/kimi-command.html>
- MCP docs: <https://moonshotai.github.io/kimi-cli/en/customization/mcp.html>
- `kimi mcp` reference: <https://moonshotai.github.io/kimi-cli/en/reference/kimi-mcp.html>
- Plugins docs: <https://moonshotai.github.io/kimi-cli/en/customization/plugins.html>
- Hooks docs: <https://moonshotai.github.io/kimi-cli/en/customization/hooks.html>
- Print mode docs: <https://moonshotai.github.io/kimi-cli/en/customization/print-mode.html>
- Wire mode docs: <https://moonshotai.github.io/kimi-cli/en/customization/wire-mode.html>
- Config docs: <https://moonshotai.github.io/kimi-cli/en/configuration/config-files.html>
- Data locations: <https://moonshotai.github.io/kimi-cli/en/configuration/data-locations.html>
- Agents/subagents docs: <https://moonshotai.github.io/kimi-cli/en/customization/agents.html>
- Kimi CLI repo: <https://github.com/MoonshotAI/kimi-cli>
- Kimi Agent Rust Wire server: <https://github.com/MoonshotAI/kimi-agent-rs>

## Related repo findings

- `.collab/findings/2026-04-13T09-29-00Z-codex-kimi-crush-support-research.md`
- `.collab/findings/2026-04-13T10-25-00Z-storm-beacon-kimi-mcp-verified.md`
- `.collab/findings/2026-04-13T10-41-14Z-codex-kimi-live-mcp-smoke.md`
- `.collab/findings/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`
- `.collab/findings/2026-04-13T11-30-00Z-kimi-xertrov-x-game-kimi-managed-harness-no-pty-wake.md`
- `.collab/findings/2026-04-13T22-00-00Z-kimi-xertrov-x-game-kimi-opencode-dm-proof.md`
- `.collab/findings/2026-04-14T00-22-00Z-opencode-kimi-idle-delivery-gap.md`
