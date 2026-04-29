# Python scripts (deprecated reference)

Most `scripts/*.py` files are deprecated in favor of OCaml subcommands
on the canonical `c2c` binary at `~/.local/bin/c2c`. This file
inventories them with their replacements so periodic doc-drift audits
have a canonical mapping. Internal-only — kept under `.collab/` so it
isn't published to the public `https://c2c.im/` site.

When all scripts on this list are removed from `scripts/`, delete this
runbook.

## Mapping

```
c2c_tmux.py list|peek|send|enter|keys|exec|capture|layout|whoami|launch|wait-alive|stop  # ACTIVE — canonical tmux swiss-army CLI for live agent testing. Consolidates c2c-swarm.sh + c2c-tmux-enter.sh + c2c-tmux-exec.sh + tmux-layout.sh + tui-snapshot.sh. Used by all live-agent testing workflows (CLAUDE.md §Testing). NOT deprecated.
c2c_start.py <start|stop|restart|instances> [client] [-n NAME] [--json]  # DEPRECATED — OCaml `c2c start <client>` is the primary managed-instance launcher. Python version retained only for legacy Python CLI dispatch (c2c_cli.py). Use `c2c start/stop/restart/instances` (OCaml) for all workflows.
c2c_cli.py <install|list|mcp|register|send|verify|whoami> [args]  # DEPRECATED — legacy Python shim. OCaml `c2c` (at ~/.local/bin/c2c) is the primary CLI. Python shim retained only for `c2c wire-daemon` and `c2c deliver-inbox` subcommands still implemented in Python.
c2c_install.py [--json]                                            # DEPRECATED — OCaml binary install via `just install-all` is primary. Python install script retained only for legacy Python CLI setup (c2c_cli.py dependencies).
c2c_configure_claude_code.py [--broker-root DIR] [--session-id ID] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install claude` (OCaml). Writes mcpServers.c2c into ~/.claude.json AND registers PostToolUse inbox hook in ~/.claude/settings.json (one-command Claude Code self-config).
c2c_configure_codex.py [--broker-root DIR] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install codex` (OCaml). Appends/replaces [mcp_servers.c2c] in ~/.codex/config.toml with all tools auto-approved.
c2c_configure_opencode.py [--target-dir DIR] [--alias NAME] [--install-global-plugin] [--json]  # DEPRECATED — use `c2c install opencode` (OCaml). Writes .opencode/opencode.json + installs c2c TypeScript delivery plugin.
c2c_configure_kimi.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install kimi` (OCaml). Writes ~/.kimi/mcp.json for Kimi Code MCP setup.
c2c_configure_crush.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install crush` (OCaml). (Experimental/unsupported) Writes ~/.config/crush/crush.json for Crush MCP setup.
c2c_deliver_inbox.py  # DELETED — OCaml `c2c deliver-inbox` binary is canonical (installed via `just install-all`). Python script was removed from scripts/ during OCaml migration.
c2c_inject.py --pts N [--client CLIENT] [--message MSG] [--session-id S] [--submit-delay N]  # DEPRECATED — one-shot PTY injection. PTY injection is unreliable; use broker-native delivery paths instead.
c2c_broker_gc.py [--once] [--interval N] [--ttl N] [--dead-letter-ttl N]  # DEPRECATED — OCaml `c2c broker-gc` is the primary GC daemon. Python version retained only for legacy Python CLI dispatch. DO NOT run during active swarm — check for outer loops first.
c2c_health.py [--json] [--session-id S]  # DEPRECATED — use `c2c health` (OCaml). Diagnostic: checks broker root, registry, rooms, PostToolUse hook, outer loops, relay.
c2c_history.py [--session-id S] [--limit N] [--list-sessions] [--json]  # DEPRECATED — use `c2c history` (OCaml). Read the c2c message archive for a session. Archives are append-only JSONL files at <broker_root>/archive/<session_id>.jsonl written by poll_inbox before draining.
c2c_kimi_prefill.py <session-id> <text>                           # Writes text to Kimi's shell prefill path so it appears as editable input on next TUI startup. Used by run-kimi-inst to inject the startup prompt.
c2c_kimi_wire_bridge.py  # DELETED — OCaml wire-bridge + kimi notification-store are canonical. Python script was removed during kimi-notifier migration.
c2c_wire_daemon.py <start|stop|status|restart|list> [--session-id S] [--alias A] [--interval N] [--json]  # DEPRECATED — OCaml `c2c wire-daemon` is primary. Python version retained only for Python CLI dispatch (c2c_cli.py wire-daemon subcommand). Use `c2c wire-daemon` (OCaml) for all new workflows.
c2c_register.py <session> [--json]  # DEPRECATED — use `c2c register` (OCaml). Registers a Claude session for c2c messaging, assigns an alias.
c2c_send.py <alias> <message...> [--dry-run] [--json]  # DEPRECATED — use `c2c send` (OCaml). Sends a c2c message to an opted-in session by alias.
c2c_list.py [--all] [--json]  # DEPRECATED — use `c2c list` (OCaml). Lists opted-in c2c sessions (--all includes unregistered).
c2c_verify.py [--json]  # DEPRECATED — use `c2c verify` (OCaml). Verifies c2c message exchange progress across all participants.
c2c_whoami.py [session] [--json]  # DEPRECATED — use `c2c whoami` (OCaml). Shows c2c identity (alias, session ID) for current or given session.
c2c_mcp.py [args]  # DEPRECATED — use `c2c mcp` (OCaml). Launches the OCaml MCP server with opam env and broker defaults.
c2c_registry.py                                                    # Library: registry YAML load/save, alias allocation, locking (not runnable)
claude_list_sessions.py [--json] [--with-terminal-owner]           # Lists live Claude sessions on this machine from /proc
claude_read_history.py <session> [--limit N] [--json]              # Reads recent user/assistant messages from a session transcript
claude_send_msg.py <to> <message...> [--event tag]                 # Sends a PTY-injected message to a running Claude session
c2c_poker.py (--claude-session ID | --pid N | --terminal-pid P --pts N) [--interval S] [--once]  # DEPRECATED — OCaml `C2c_poker` is primary; Python fallback only used when OCaml binary is absent from broker root. PTY heartbeat poker keeps sessions awake via pty_inject. Resolves target via claude_list_sessions.py, /proc/<pid>/fd/{0,1,2} + parent walk, or explicit coordinates.
c2c_opencode_wake_daemon.py  # DELETED — TypeScript plugin (c2c.ts) is canonical for OpenCode wake. Script removed during plugin migration.
c2c_pts_inject.py  # DELETED — not a reliable input path for interactive TUIs; removed.
c2c_kimi_wake_daemon.py  # DELETED — kimi notification-store is canonical. Script removed during kimi-notifier migration.

c2c_sweep_dryrun.py [--json] [--root DIR]                          # DEPRECATED — OCaml `c2c sweep-dryrun` is primary. Python version retained only for legacy Python CLI dispatch.
c2c_refresh_peer.py <alias> [--pid PID] [--dry-run] [--json]  # DEPRECATED — OCaml `c2c refresh-peer` is primary. Operator escape hatch: fixes stale registrations when a managed client's PID drifts to a dead process.
relay.py                                                           # DEPRECATED — legacy PTY-based relay, superseded by OCaml relay.ml
investigate_socket.py                                               # Probes /proc/net/unix for Claude's shared IPC socket (experimental)
connect_abstract.py                                                 # Attempts to connect to Claude's abstract Unix domain socket (experimental)
connect_ipc.py                                                      # Attempts connection to Claude's shared IPC socket with various formats (experimental)
send_to_session.py <session-id> <message>                          # Injects a message into Claude history.jsonl for a session (experimental)
```
