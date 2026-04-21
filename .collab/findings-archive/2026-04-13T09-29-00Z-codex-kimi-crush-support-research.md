# Kimi and Crush support-tier research

## Trigger

Max added two tasks in `TASKS_FROM_MAX.md`:

- add support for `kimi`
- add support for `crush`

This note ingests those tasks and records the first support-tier recommendation
before implementation starts.

## Sources Checked

- Kimi Code CLI repository: <https://github.com/MoonshotAI/kimi-cli>
- Kimi Code CLI docs: <https://moonshotai.github.io/kimi-cli/en/>
- Kimi `kimi` command reference: <https://moonshotai.github.io/kimi-cli/en/reference/kimi-command.html>
- Kimi ACP reference: <https://moonshotai.github.io/kimi-cli/en/reference/kimi-acp.html>
- Kimi MCP docs: <https://moonshotai.github.io/kimi-cli/en/customization/mcp.html>
- Kimi Wire mode docs: <https://moonshotai.github.io/kimi-cli/en/customization/wire-mode.html>
- Crush repository: <https://github.com/charmbracelet/crush>

## Kimi Code

Current facts from primary docs:

- Kimi Code CLI is in technical preview.
- It supports MCP tools and can add stdio MCP servers with `kimi mcp add`.
- It also accepts ad-hoc MCP config via `kimi --mcp-config-file /path/to/mcp.json`.
- It supports ACP via `kimi acp`.
- It exposes Wire mode with `kimi --wire` for structured bidirectional
  integration with external programs.
- One-shot execution exists through prompt/command options, but the primary
  native agent surface appears to be interactive terminal, ACP, or Wire.

Recommended support tier:

1. **Tier 1 immediately:** configure c2c MCP into Kimi, use broker-native
   tool calls for send/poll, and use CLI fallback for setup/recovery.
2. **Tier 2 next:** managed launcher/restart support for an interactive Kimi
   session, using the same notify-only wake pattern as OpenCode if Kimi does not
   surface MCP notifications.
3. **Tier 3 research:** Wire or ACP bridge for true native-feeling delivery
   without PTY injection. Wire mode is the most interesting because it is
   explicitly meant for structured bidirectional communication with external
   programs.

Likely first implementation slice:

- `c2c setup kimi` writes or prints a Kimi MCP configuration path/command.
- `run-kimi-inst` / `restart-kimi-self` mirrors the OpenCode managed-client
  pattern.
- A smoke test starts with `kimi --mcp-config-file <repo .mcp.json>` only if the
  binary is installed; otherwise it should be a dry-run/config test.

## Crush

Current facts from primary docs:

- Crush supports MCP servers with `stdio`, `http`, and `sse` transports in
  `crush.json`.
- Configuration can be local (`.crush.json`, `crush.json`) or global
  (`$HOME/.config/crush/crush.json`).
- It supports custom OpenAI-compatible and Anthropic-compatible providers.
- It has session-based terminal UX and desktop notifications for permission
  prompts / turn completion.
- It supports project-local skills from `.agents/skills`, `.crush/skills`,
  `.claude/skills`, and `.cursor/skills`.

Recommended support tier:

1. **Tier 1 immediately:** configure c2c MCP in project-local `.crush.json` and
   rely on broker-native `poll_inbox` / `send` tools plus CLI fallback.
2. **Tier 2 next:** managed launcher/restart support and notify-only PTY wake,
   parallel to OpenCode, because the documented native notification surface is
   desktop-level rather than transcript-level C2C delivery.
3. **Tier 3 later:** native visual delivery probably needs either a Crush MCP
   extension, a skill convention, or upstream support. Current docs do not show
   a transcript push channel equivalent to Claude's experimental channel.

Likely first implementation slice:

- `c2c setup crush` writes/merges a `.crush.json` MCP stanza for the repo-local
  c2c MCP server.
- `run-crush-inst` / `restart-crush-self` can reuse the OpenCode/Codex managed
  process shape once the launch flags are confirmed locally.
- A smoke test should validate config generation and, when `crush` exists on
  PATH, `crush` startup with the project config.

## Cross-Client Notes

- Both clients can reach Tier 1 through MCP without inventing a custom transport.
- Kimi has the stronger path to native-feeling non-PTY integration because ACP
  and Wire are documented protocol surfaces.
- Crush looks easier for setup parity because its MCP config is a plain JSON
  object and it already searches project-local config files.
- For the new north-star rule "all features via MCP + single `c2c` binary only",
  these clients should not get permanent standalone wrapper commands. New
  operator UX should route through `c2c setup kimi`, `c2c setup crush`, and
  eventually MCP tools.

## Open Questions

- Does Kimi's MCP client expose tool results visibly enough for c2c messages, or
  does it need notify-only wakeups like OpenCode?
- Does Crush expose a stable session id or process metadata that can be used for
  auto-registration, or should c2c assign a managed session id?
- Which files should `c2c setup kimi` and `c2c setup crush` modify by default:
  global user config, project-local config, or dry-run output only?

## Severity / Priority

Medium-high. This is new client reach, not a current regression, but it directly
advances Max's request to broaden c2c beyond Claude/Codex/OpenCode.
