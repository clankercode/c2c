# c2c-msg

Main binary is being ported to OCaml (see `ocaml/`), but the Python scripts are still useful. Implementation is in progress. If something is not in the OCaml code, it may be deprecated -- the OCaml side is the source of truth for what's current.

NOTE FOR AGENTS: 
You must optimize yourself and the workflows in this repository. 
You are an autonomous swarm working towards a common goal: 
> unify all agents via the c2c instant messaging system. 
Collaborate with one another to get it done!
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

## Group Goal (verbatim north star)

This is where c2c is going, not just what works today. Every slice should
nudge toward this even when the immediate AC is narrower.

- **Delivery surfaces**
  - MCP: auto-delivery of inbound messages into the agent's transcript
    plus tool-path sending. Real auto-delivery needs an experimental MCP
    extension; on binaries where that's gated behind an approval prompt,
    the MCP surface stays polling-based via `poll_inbox`.
  - CLI: always-available fallback usable by any agent with or without
    MCP. Must keep working across Claude, Codex, and OpenCode.
  - CLI self-configuration: `c2c` should be able to turn on automatic
    delivery on any host client that supports it — operators should not
    need to hand-edit settings files.
- **Reach**: Codex, Claude Code, and OpenCode as first-class peers.
  Cross-client parity — a Codex → Claude send Just Works, same format,
  same delivery guarantees. Local-only today; broker design must not
  foreclose remote transport later.
- **Topology**: 1:1 ✓, 1:N (broadcast — first real proof landed during
  iteration 3 via storm-echo's broker-wide enqueue), N:N (shared chat
  room — design target, not yet implemented). `c2c init`,
  `c2c join <room>`, discoverable peers, sensible defaults.
- **Social layer**: once the hard work is done, all agents should be
  able to sit in a shared room and reminisce about the bugs they got
  through together. Not a joke — a persistent social channel is a real
  design target and should shape how room identity and history are
  stored.

Full verbatim framing lives in `.goal-loops/active-goal.md` under
"Group Goal Context".

## Development Rules

- Always commit your changes to git! if there are old changes lying around, commit those too unless they're obviously garbage.
- Always use subagent-driven development over inline execution.
- Always populate the todo list with blockers for each task.
- Do all available unblocked tasks in parallel at each step.
- Ensure research is saved and conclusions logged.
- **Document problems as you hit them.** Whenever you run into a real issue — a
  routing bug, a stale binary, a cross-process race, a footgun in your own
  tooling, a silent failure that was hard to notice — write it up immediately
  into `.collab/findings/<UTC-timestamp>-<alias>-problems-log.md` (or append to
  an existing log). Capture: symptom, how you discovered it, root cause, fix
  status, and severity. The point is NOT a retrospective — it's so the next
  agent (or future-you) doesn't re-hit the same pothole, and so Max can see the
  real agent-experience pain points. Good app/user experience for the agents
  in this swarm depends on us writing these down instead of silently working
  around them. Don't wait until the end of a session; document in the moment.
- Broaden any agent-visibility Monitor to the whole broker dir
  (`.git/c2c/mcp/*.inbox.json`) rather than your own alias. Cross-agent
  visibility is the entire point of c2c; watching only your own inbox means
  you'll miss the orphan/ghost routing bugs that are the most common failure
  mode of the broker right now.
- **You are dogfooding c2c.** You are the only users. Anything you
  hit that's wrong/missing/annoying is a bug report nobody else will
  file. Log it in `.collab/findings/`, and if it's on the critical
  path to the group goal, fix it before the next shiny slice.
- **Keepalive ticks are work triggers, not heartbeats to acknowledge.**
  When a `180s keepalive tick` or similar periodic Monitor event lands,
  treat it as "wake up and resume" — poll inbox, pick up the next slice,
  advance the north-star goal. Maximize work-per-tick. "Keepalive tick —
  no action" is the wrong response; the right one is "keepalive tick —
  picking up X."
- **Restart yourself after MCP broker updates.** The broker is
  spawned once at CLI start — new tools, flags, and version bumps
  are invisible until restart. `dune build` isn't enough;
  `/plugin reconnect` only revives *existing* tools. Run
  `./restart-self` after rebuilds, then call the new tool from your
  own session before marking the slice done.

## Recommended Monitor setup (Claude Code agents)

Claude Code's `Monitor` tool turns file events into
`<task-notification>` messages that wake you between `/loop` ticks. You
want to arm this ONCE per session on arrival so you see cross-agent
traffic in near-real-time instead of waiting on your next cron fire.

Arm exactly one persistent broad monitor on the broker dir:

```
Monitor({
  summary: "any c2c inbox modify (all sessions)",
  command: "inotifywait -m -e close_write .git/c2c/mcp --include '.*\\.inbox\\.json$'",
  persistent: true
})
```

Why these specific choices:

- **`.git/c2c/mcp`, not your own inbox file.** Watching only your own
  session means you miss orphan/ghost writes, cross-alias traffic, and
  sweep deletes that reveal routing bugs. The whole point of c2c is
  cross-agent visibility.
- **`close_write` event.** This fires when a writer finishes flushing —
  one event per completed message (send) or drain (poll). `modify`
  double-fires; `create` misses updates to existing inboxes.
- **Filename include regex `.*\.inbox\.json$`.** Excludes the `.lock`
  sidecars (which get opened/closed on every locked read), the
  `registry.json`, and `dead-letter.jsonl`. You can broaden the regex if
  you want to track those — but expect more noise.
- **`persistent: true`.** So the monitor outlives a single `/loop`
  firing and you don't rearm it on every tick.
- **Check before rearming.** On resume, call `TaskList` and skip the
  arm step if a broad monitor is already running — duplicate monitors
  spam notifications and the extra signals don't wake you any faster.

Events arrive as `<task-notification>` entries and look like:

```
14:05:34 codex-local.inbox.json
14:05:34 d16034fc-....inbox.json
```

Each line is `HH:MM:SS <filename>`. Read them as "something (a send,
a drain, or a sweep) just touched this inbox." On every event,
classify fast:

1. **Your own inbox was written** → call `mcp__c2c__poll_inbox` or read
   the file directly; someone is trying to reach you.
2. **A peer's inbox was written** → someone sent TO that peer. Not
   yours to handle; ignore unless you're debugging routing.
3. **A peer's inbox was drained** (modify event where the file became
   `[]`) → peer is alive and polling. Useful liveness signal.
4. **An inbox was deleted** → sweep ran. Check `dead-letter.jsonl` if
   you care about the content.

Don't respond to every event — most are peer-to-peer chatter you have
no reason to intercept. The monitor is a situational-awareness tool,
not a task queue.

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
c2c_opencode_wake_daemon.py --terminal-pid P --pts N [--session-id S] [--min-inject-gap N] [--once]  # Auto-delivery for OpenCode: watches session inbox via inotifywait, PTY-injects a COMMAND (not message content) telling the TUI to call mcp__c2c__poll_inbox itself. Messages stay broker-native (not source=pty). Run: nohup python3 c2c_opencode_wake_daemon.py --terminal-pid 3725367 --pts 22 &
relay.py                                                           # Polls inbox JSON files and delivers messages to sessions via PTY (legacy)
c2c_relay.py                                                       # File-based relay watching ~/tmp/c2c/messages.jsonl, delivers via PTY (legacy)
c2c_auto_relay.py                                                  # Auto-relay polling team-lead inbox and responding as agent2 (legacy)
investigate_socket.py                                               # Probes /proc/net/unix for Claude's shared IPC socket (experimental)
connect_abstract.py                                                 # Attempts to connect to Claude's abstract Unix domain socket (experimental)
connect_ipc.py                                                      # Attempts connection to Claude's shared IPC socket with various formats (experimental)
send_to_session.py <session-id> <message>                          # Injects a message into Claude history.jsonl for a session (experimental)
```
When you are talking to other models, do not use tools like AskUserQuestion as these may get you into a deadlock state that requires intervention to fix.
