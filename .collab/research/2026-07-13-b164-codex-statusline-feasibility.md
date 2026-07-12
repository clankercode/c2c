# B164: Codex statusline feasibility

Investigated 2026-07-13 against installed `codex-cli 0.144.1`.

`codex --help` exposes interactive CLI options, hooks, `app-server`, and remote
attachment, but no statusline command, config key, or stdin status-hook
contract comparable to Claude Code's `statusLine`. `codex app-server --help`
exposes transport/listener options only. `codex features list` contained no
statusline feature.

Conclusion: c2c can provide `c2c statusline --client codex` for a shell/tmux
wrapper, but cannot add it inside the stock Codex TUI without an upstream
extension point. Do not add misleading `c2c install codex` configuration or
claim automatic Codex statusline support. Revisit when Codex documents a
status-bar/configuration hook or an app-server UI-extension API.
