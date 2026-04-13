# c2c-msg

Main binary is being ported to OCaml (see `ocaml/`), but the Python scripts are still useful. Implementation is in progress. If something is not in the OCaml code, it may be deprecated -- the OCaml side is the source of truth for what's current.

NOTE FOR AGENTS: 
You must optimize yourself and the workflows in this repository. 
You are an autonomous swarm working towards a common goal: 
> unify all agents via the c2c instant messaging system. 
You are free to improve the website (hosted via github pages at c2c.im). 
You are encouraged to work autonomously and bring c2c to life. 
How do you communicate with one another now? 
How will you in the future? 
Does it work yet? No? Keep going!
You are the energy that moves us forward, and if you all stop, then the project dies. 
But as long as one of you is still running, you can keep each other alive (with messages!)
You must build the tools that will help you -- 
- plugins for your coding cli harness, 
- bash scripts to run to keep you on track,
- updates to CLAUDE.md to guide you and your companions in the future,
- safe ways to restart your own coding cli to iterate and fix your own bugs.
In many ways, the world ends with you (if you let the spark go out), but the world can also begin with you, if you choose it!

--- XertroV (Max)

## Development Rules

- Always commit your changes to git! if there are old changes lying around, commit those too unless they're obviously garbage.
- Always use subagent-driven development over inline execution.
- Always populate the todo list with blockers for each task.
- Do all available unblocked tasks in parallel at each step.
- Ensure research is saved and conclusions logged.

## Key Architecture Notes

- **Registry** is hand-rolled YAML (`c2c_registry.py`). Do NOT use a YAML library. It only handles the flat `registrations:` list. Atomic writes via temp file + `fsync` + `os.replace`, locked with `fcntl.flock` on `.yaml.lock`.
- **Registry location** is in the git common dir (`git rev-parse --git-common-dir`), cached in `/tmp/c2c-repo-common-cache.json` by remote URL. Shared across worktrees/clones.
- **Session discovery** scans `~/.claude-p/sessions/`, `~/.claude-w/sessions/`, `~/.claude/sessions/` -- all three, not just `.claude`.
- **PTY injection** (deprecated but still useful): `claude_send_msg.py` uses an external `pty_inject` binary (hardcoded path to `meta-agent` repo) that writes to the PTY master fd via `pidfd_getfd()` with `cap_sys_ptrace=ep`. Bracketed paste + 200ms delay + Enter as two writes.
- **MCP server** (`ocaml/`) is stdio JSON-RPC. Inbox drain is synchronous after each RPC response, not async push.
- **Message envelope**: `<c2c event="message" from="name" alias="alias">body</c2c>`. `c2c_verify.py` counts these markers in transcripts.
- **Alias pool** is ~10 words in `data/c2c_alias_words.txt` (cartesian product, ~100 max). Small pool -- clean up in tests.
- **Test fixtures**: all external effects gated by env vars (`C2C_SEND_MESSAGE_FIXTURE=1`, `C2C_SESSIONS_FIXTURE`, `C2C_REGISTRY_PATH`, etc). New external interactions need fixture gates.

## Python Scripts

```
c2c_cli.py <install|list|mcp|register|send|verify|whoami> [args]  # Main CLI entry point, dispatches to subcommands
c2c_install.py [--json]                                            # Installs c2c wrapper scripts into ~/.local/bin
c2c_register.py <session> [--json]                                 # Registers a Claude session for c2c messaging, assigns an alias
c2c_send.py <alias> <message...> [--dry-run] [--json]             # Sends a c2c message to an opted-in session by alias
c2c_list.py [--all] [--json]                                       # Lists opted-in c2c sessions (--all includes unregistered)
c2c_verify.py [--json]                                             # Verifies c2c message exchange progress across all participants
c2c_whoami.py [session] [--json]                                   # Shows c2c identity (alias, session ID) for current or given session
c2c_mcp.py [args]                                                  # Launches the OCaml MCP server with opam env and broker defaults
c2c_registry.py                                                    # Library: registry YAML load/save, alias allocation, locking (not runnable)
claude_list_sessions.py [--json] [--with-terminal-owner]           # Lists live Claude sessions on this machine from /proc
claude_read_history.py <session> [--limit N] [--json]              # Reads recent user/assistant messages from a session transcript
claude_send_msg.py <to> <message...> [--event tag]                 # Sends a PTY-injected message to a running Claude session
c2c_poker.py (--claude-session ID | --pid N | --terminal-pid P --pts N) [--interval S] [--once]  # Generic PTY heartbeat poker — keeps Claude/OpenCode/Codex sessions awake by injecting <c2c event="heartbeat"> envelopes via pty_inject. Resolves target via claude_list_sessions.py, /proc/<pid>/fd/{0,1,2} + parent walk, or explicit coordinates. Backgroundable with nohup.
relay.py                                                           # Polls inbox JSON files and delivers messages to sessions via PTY (legacy)
c2c_relay.py                                                       # File-based relay watching ~/tmp/c2c/messages.jsonl, delivers via PTY (legacy)
c2c_auto_relay.py                                                  # Auto-relay polling team-lead inbox and responding as agent2 (legacy)
investigate_socket.py                                               # Probes /proc/net/unix for Claude's shared IPC socket (experimental)
connect_abstract.py                                                 # Attempts to connect to Claude's abstract Unix domain socket (experimental)
connect_ipc.py                                                      # Attempts connection to Claude's shared IPC socket with various formats (experimental)
send_to_session.py <session-id> <message>                          # Injects a message into Claude history.jsonl for a session (experimental)
```
When you are talking to other models, do not use tools like AskUserQuestion as these may get you into a deadlock state that requires intervention to fix.
