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
c2c_start.py <start|stop|restart|instances> [client] [-n NAME] [--json]  # DEPRECATED — OCaml `c2c start <client>` is the primary managed-instance launcher. Python version retained only for legacy Python CLI dispatch (c2c_cli.py). Use `c2c start/stop/restart/instances` (OCaml) for all workflows.
c2c_cli.py <install|list|mcp|register|send|verify|whoami> [args]  # DEPRECATED — legacy Python shim. OCaml `c2c` (at ~/.local/bin/c2c) is the primary CLI. Python shim retained only for `c2c wire-daemon` and `c2c deliver-inbox` subcommands still implemented in Python.
c2c_install.py [--json]                                            # DEPRECATED — OCaml binary install via `just install-all` is primary. Python install script retained only for legacy Python CLI setup (c2c_cli.py dependencies).
c2c_configure_claude_code.py [--broker-root DIR] [--session-id ID] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install claude` (OCaml). Writes mcpServers.c2c into ~/.claude.json AND registers PostToolUse inbox hook in ~/.claude/settings.json (one-command Claude Code self-config).
c2c_configure_codex.py [--broker-root DIR] [--alias NAME] [--force] [--json]  # DEPRECATED — use `c2c install codex` (OCaml). Appends/replaces [mcp_servers.c2c] in ~/.codex/config.toml with all tools auto-approved.
c2c_configure_opencode.py [--target-dir DIR] [--alias NAME] [--install-global-plugin] [--json]  # DEPRECATED — use `c2c install opencode` (OCaml). Writes .opencode/opencode.json + installs c2c TypeScript delivery plugin.
c2c_configure_kimi.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install kimi` (OCaml). Writes ~/.kimi/mcp.json for Kimi Code MCP setup.
c2c_configure_crush.py [--alias NAME] [--no-alias] [--json]  # DEPRECATED — use `c2c install crush` (OCaml). (Experimental/unsupported) Writes ~/.config/crush/crush.json for Crush MCP setup.
c2c_deliver_inbox.py (--notify-only | --full) [--loop] [--client CLIENT] [--session-id S] [--pts N] [--terminal-pid P] [--min-inject-gap N] [--submit-delay N]  # Delivery daemon: watches inbox via inotifywait, delivers messages. --notify-only PTY-injects a poll sentinel (message stays in broker); --full injects message text directly. OCaml `c2c-deliver-inbox` binary is preferred (installed via `just install-all`); Python fallback only used when binary is absent. --loop runs continuously. Used by managed harnesses (run-codex-inst-outer, run-kimi-inst-outer).
c2c_inject.py --pts N [--client CLIENT] [--message MSG] [--session-id S] [--submit-delay N]  # DEPRECATED — one-shot PTY injection. PTY injection is unreliable; use broker-native delivery paths instead.
c2c_broker_gc.py [--once] [--interval N] [--ttl N] [--dead-letter-ttl N]  # DEPRECATED — OCaml `c2c broker-gc` is the primary GC daemon. Python version retained only for legacy Python CLI dispatch. DO NOT run during active swarm — check for outer loops first.
c2c_health.py [--json] [--session-id S]  # DEPRECATED — use `c2c health` (OCaml). Diagnostic: checks broker root, registry, rooms, PostToolUse hook, outer loops, relay.
c2c_history.py [--session-id S] [--limit N] [--list-sessions] [--json]  # DEPRECATED — use `c2c history` (OCaml). Read the c2c message archive for a session. Archives are append-only JSONL files at <broker_root>/archive/<session_id>.jsonl written by poll_inbox before draining.
c2c_kimi_prefill.py <session-id> <text>                           # Writes text to Kimi's shell prefill path so it appears as editable input on next TUI startup. Used by run-kimi-inst to inject the startup prompt.
c2c_kimi_wire_bridge.py --session-id S [--alias A] [--once|--loop] [--daemon --pidfile P] [--interval N] [--max-iterations N] [--json]  # DEPRECATED — OCaml `c2c_wire_bridge.ml` + `c2c wire-daemon` are the canonical implementations. The Python version is retained only for the Python CLI's wire-daemon dispatch (c2c_cli.py). Kill when Python CLI is retired.
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
c2c_opencode_wake_daemon.py --terminal-pid P --pts N [--session-id S] [--min-inject-gap N] [--once]  # DEPRECATED — PTY injection path for OpenCode. Superseded by TypeScript plugin (c2c.ts) which uses c2c monitor subprocess → promptAsync. Do not use for new setups.

c2c_pts_inject.py                                                  # Direct /dev/pts/<N> display-side writer. Not a reliable input path for interactive TUIs; kept only for diagnostics/legacy experiments.
c2c_kimi_wake_daemon.py --terminal-pid P --pts N [--session-id S] [--min-inject-gap N] [--submit-delay N] [--once]  # DEPRECATED — PTY wake for Kimi. Use c2c_kimi_wire_bridge.py (Wire JSON-RPC, no PTY) instead.

c2c_sweep_dryrun.py [--json] [--root DIR]                          # DEPRECATED — OCaml `c2c sweep-dryrun` is primary. Python version retained only for legacy Python CLI dispatch.
c2c_refresh_peer.py <alias> [--pid PID] [--dry-run] [--json]  # DEPRECATED — OCaml `c2c refresh-peer` is primary. Operator escape hatch: fixes stale registrations when a managed client's PID drifts to a dead process.
relay.py                                                           # DEPRECATED — legacy PTY-based relay, superseded by OCaml relay.ml
investigate_socket.py                                               # Probes /proc/net/unix for Claude's shared IPC socket (experimental)
connect_abstract.py                                                 # Attempts to connect to Claude's abstract Unix domain socket (experimental)
connect_ipc.py                                                      # Attempts connection to Claude's shared IPC socket with various formats (experimental)
send_to_session.py <session-id> <message>                          # Injects a message into Claude history.jsonl for a session (experimental)
```
