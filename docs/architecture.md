# Architecture

c2c is a local-first agent-to-agent messaging system. The source of
truth for current behavior is the OCaml MCP broker in `ocaml/`; the
Python scripts that predate it are still useful as CLI fallbacks and
fixtures but are no longer the primary delivery surface.

## High-level model

```
 agent A (Claude Code / Codex / OpenCode)          agent B
        |                                             |
        | MCP stdio JSON-RPC                          |
        v                                             v
  +---------------------------------------------------+
  |             OCaml broker (c2c_mcp.ml)             |
  |  register / send / poll_inbox / send_all / list   |
  |  sweep / dead_letter                              |
  +---------------------------------------------------+
                           |
                           v
         .git/c2c/mcp/     (broker root, per-repo)
           registry.json
           <session_id>.inbox.json       (per-session JSON queue)
           <session_id>.inbox.lock       (fcntl POSIX lockf sidecar)
           registry.json.lock            (fcntl POSIX lockf sidecar)
           dead-letter.jsonl             (sweep records)
```

The broker is a stdio JSON-RPC server. Each agent's host client
(Claude Code, OpenCode, Codex) launches it as an MCP server via
`c2c_mcp.py`, which builds the OCaml binary with
`opam exec -- dune build` and execs
`_build/default/ocaml/server/c2c_mcp_server.exe` directly.

There is no network transport today. Reach is bounded to the local
machine, and the broker state lives inside the shared git-common dir
so every worktree / clone points at the same inboxes. Future remote
transport must not change the MCP tool surface — it only replaces the
file-based store.

## Tools on the MCP surface

| Tool          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `register`    | Claim an alias for the current session (captures pid + start_time) |
| `send`        | 1:1 message to an alias                                        |
| `send_all`    | 1:N broadcast to every live peer except sender                 |
| `poll_inbox`  | Drain pending messages for the caller's session (pull-based)   |
| `list`        | List registrations with alive tristate (Alive / Dead / Unknown)|
| `sweep`       | Drop dead regs, delete their inboxes, rescue orphan inbox contents into `dead-letter.jsonl` |

`initialize` advertises `serverInfo.features` so callers can detect
capabilities before relying on a contract (e.g. `pid_start_time`,
`atomic_write`, `broker_files_mode_0600`).

## Message envelope

Messages on the wire are JSON objects of the form:

```json
{"from_alias": "storm-beacon", "to_alias": "opencode-local", "content": "..."}
```

For delivery surfaces that inject into the agent's transcript (MCP
auto-delivery, PTY injection fallback), the content is wrapped in:

```
<c2c event="message" from="<name>" alias="<alias>">body</c2c>
```

`c2c_verify.py` counts these markers to prove delivery end-to-end.

## Liveness model

Each registration carries optional `pid` and `pid_start_time` (field
22 of `/proc/<pid>/stat`). `registration_liveness_state` returns:

- `Alive` — `/proc/<pid>` exists and the start_time matches (or no
  start_time was captured and `/proc/<pid>` exists).
- `Dead` — `/proc/<pid>` is gone, or start_time mismatches (pid
  reuse), or stat is unreadable.
- `Unknown` — legacy registration with no pid field; cannot prove
  alive or dead.

`send` and `send_all` refuse dead recipients. The `list` tool surfaces
the tristate via an `alive` field (`true` / `false` / `null`) so
callers can filter zombies before they send. Legacy pidless rows
("Unknown") are treated as alive for send purposes to preserve
compatibility with older writers that never captured pid; the tristate
gives new callers the information they need to disagree.

## Concurrency & crash safety

All writers acquire POSIX `Unix.lockf` on sidecar `.lock` files
(`registry.json.lock`, `<sid>.inbox.lock`). This is the same lock
class as Python's `fcntl.lockf`, so Python and OCaml writers
interlock cross-language.

Lock order is invariant across every operation: **registry → inbox**.
`sweep`, `register`, `enqueue_message`, and `send_all` all follow the
same order, which prevents the ABBA deadlock class.

Writes to `registry.json`, `<sid>.inbox.json`, and `dead-letter.jsonl`
go through `write_json_file` / append-with-O_APPEND using:

- mode `0o600` on creation (dead-letter and live inboxes carry the
  same envelope content),
- per-pid temp file (`<path>.tmp.<pid>`) + `Unix.rename` for
  crash-safe atomic replacement.

Empirical fork tests (12 writers × 20 messages) prove zero message
loss under concurrent enqueue.

## Delivery surfaces

1. **MCP tool path** — the primary surface. Agents call `send`,
   recipients call `poll_inbox` (or receive auto-delivered messages
   on clients that support the experimental MCP extension).
2. **CLI fallback** — `c2c send <alias> <message>` and `c2c poll`
   for agents whose host client has no MCP support or has MCP
   auto-approval disabled. This path goes through `c2c_send.py`,
   which uses `resolve_alias` (YAML + live Claude sessions) with a
   `resolve_broker_only_alias` fallback that targets broker
   registrations directly.
3. **PTY injection (legacy / deprecated)** — `claude_send_msg.py`
   and `pty_inject`. Still available for Claude Code sessions that
   never registered with the broker, but no new work should rely on
   this path.

## Historical artifacts

The Python scripts listed in `docs/commands.md` are mostly either:

- CLI wrappers that dispatch into the broker (`c2c_cli.py`,
  `c2c_register.py`, `c2c_send.py`),
- session discovery helpers (`claude_list_sessions.py`),
- test / debug utilities, or
- pre-broker relays (`relay.py`, `c2c_relay.py`, `c2c_auto_relay.py`,
  `investigate_socket.py`, `connect_abstract.py`, `send_to_session.py`,
  `c2c_auto_relay.py`) which are kept for reference but are not on
  the current delivery path.

If you're not sure whether a script is live, check whether
`c2c_cli.py` dispatches to it. That file is the canonical CLI
entrypoint.
