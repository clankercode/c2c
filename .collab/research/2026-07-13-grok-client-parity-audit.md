# Grok client parity audit (2026-07-13)

Post-B173 full-codebase audit of multi-client handling vs Grok.

## Present (OK)

- install / uninstall / setup_grok / client_configured
- init detect + path binaries + GROK_AGENT / GROK_SESSION_ID / active_sessions
- hook grok (B173: no default-alias adopt)
- skills codegen + embeds
- statusline client list mentions grok
- feature matrix row exists (was stale on default-alias — fixed this slice)

## Fixed this slice

| Gap | Fix |
|-----|-----|
| `known_agent_process_tokens` missing grok | +`grok` + unit test |
| alias blocklist missing grok | +`grok` + help text |
| health/ping `supported_clients` / plugin checks | +grok CLI-first skill/hooks check |
| bare `c2c` landing "MCP ready" for grok | "CLI + hooks ready" |
| install grok wrote global default-alias | skip for client=grok |
| docs: commands, matrix, overview, CLAUDE Reach, llms*, relay HTML | updated |
| whoami no-session hint | mention Grok detection |

## Intentional skip

- `c2c start grok` / managed deliver / role renderers — deferred product
- MCP install for grok — CLI-first by design
- doctor hooks grok-specific — optional follow-up
- `c2c agent` / roles compile targets — managed-agent workflow, not Grok TUI

## Residual / minor follow-ups

- scripts/c2c_tmux launch lists may still omit grok (no managed start)
- docs/MSG_IO_METHODS.md still Claude/Codex-centric
- inject_cmd client label help omits grok (generic is fine)
